// SPDX-License-Identifier: MPL-2.0
// All entry points and browser callbacks run on the AppKit main thread.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "RadiusEngineABI.h"
#include "include/cef_app.h"
#include "include/cef_command_line.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/wrapper/cef_library_loader.h"

namespace {
bool initialized = false;
bool stopped = false;
std::string last_error;
std::string data_root;
NSTimer* pump_timer = nil;
bool pumping = false;
bool diagnostics = false;
unsigned pump_count = 0;

void Trace(const char* message) {
  if (diagnostics) { std::fprintf(stderr,"Radius Chromium: %s\n",message); std::fflush(stderr); }
}
void CancelPump() {
  [pump_timer invalidate]; [pump_timer release]; pump_timer = nil;
}

void SchedulePump(int64_t delay);
class EngineApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                    CefRefPtr<CefCommandLine> command_line) override {
    // Radius enforces popup policy in OnBeforePopup. Chrome's earlier blocker
    // otherwise ignores Radius's allow toggle, especially in private contexts
    // where default content settings cannot be changed.
    if (process_type.empty()) command_line->AppendSwitch("disable-popup-blocking");
  }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    dispatch_async(dispatch_get_main_queue(), ^{ SchedulePump(delay); });
  }
 private:
  IMPLEMENT_REFCOUNTING(EngineApp);
};
CefRefPtr<EngineApp> engine_app;

void SchedulePump(int64_t delay) {
  if (!initialized || stopped) return;
  // Match CEF's external-pump sample: delayed work needs an upper bound even
  // when Chromium does not send another OnScheduleMessagePumpWork callback.
  delay = std::clamp<int64_t>(delay,0,1000 / 30);
  NSDate* date = [NSDate dateWithTimeIntervalSinceNow:delay / 1000.0];
  if (pump_timer && [[pump_timer fireDate] compare:date] != NSOrderedDescending) return;
  CancelPump();
  pump_timer = [[NSTimer timerWithTimeInterval:delay / 1000.0
                                    repeats:NO block:^(NSTimer*) {
    CancelPump();
    if (!initialized || stopped) return;
    if (pumping) { SchedulePump(1); return; }
    pumping = true;
    if (++pump_count <= 3) Trace("processing external message-pump work");
    CefDoMessageLoopWork();
    pumping = false;
    if (!pump_timer) SchedulePump(1000 / 30);
  }] retain];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSRunLoopCommonModes];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSModalPanelRunLoopMode];
}

struct Context { CefRefPtr<CefRequestContext> value; size_t pages = 0; bool ready = false; uint64_t generation = 0; };
uint64_t next_context_generation = 0;
std::map<std::string, Context> contexts;
struct Page;
class Client;
std::map<Page*, std::unique_ptr<Page>> pages;
struct Page {
  NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<Client> client;
  CefRefPtr<CefRegistration> observer;
  std::string context_key;
  std::string pending_url;
  std::string title;
  bool navigation_failed = false;
  bool closing = false;
  bool navigated = false;
  bool popups = false;
  bool awaiting_context = true;
  bool pending_popup = false;
  void* callback_context = nullptr;
  radius_cef_event_callback event = nullptr;
  radius_cef_popup_callback popup = nullptr;
  Page();
  ~Page();
};

void Emit(Page* page, int event, CefRefPtr<CefDictionaryValue> value) {
  if (!page->event) return;
  auto wrapper = CefValue::Create(); wrapper->SetDictionary(value);
  std::string json = CefWriteJSON(wrapper, JSON_WRITER_DEFAULT).ToString();
  page->event(page->callback_context, event, json.c_str());
}
void Message(Page* page, int event, const std::string& message) {
  auto value = CefDictionaryValue::Create(); value->SetString("message", message); Emit(page, event, value);
}
void State(Page* page, bool finished = false) {
  if (!page->browser || !page->navigated) return;
  auto value = CefDictionaryValue::Create();
  value->SetString("url", page->browser->GetMainFrame()->GetURL());
  value->SetString("title",page->title);
  value->SetBool("loading", page->browser->IsLoading());
  value->SetBool("canGoBack", page->browser->CanGoBack());
  value->SetBool("canGoForward", page->browser->CanGoForward());
  Emit(page, finished ? RADIUS_CEF_FINISHED : RADIUS_CEF_STATE, value);
}
bool Allowed(const std::string& url) {
  NSString* value = [NSString stringWithUTF8String:url.c_str()];
  NSURLComponents* parts = [NSURLComponents componentsWithString:value];
  NSString* scheme = [[parts scheme] lowercaseString];
  if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
    return [[parts host] length] > 0 && [parts user] == nil && [parts password] == nil;
  return [scheme isEqualToString:@"blob"] || [value isEqualToString:@"about:blank"] ||
         [value hasPrefix:@"about:blank#"];
}
void Destroy(Page* page);
Page* Allocate(const std::string& key);

class Client final : public CefClient, public CefLifeSpanHandler,
                     public CefDisplayHandler, public CefLoadHandler,
                     public CefRequestHandler, public CefDownloadHandler,
                     public CefDevToolsMessageObserver {
 public:
  explicit Client(Page* page) : page_(page) {}
  void DetachPage() { page_ = nullptr; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (!page_) return;
    if (diagnostics) {
      std::fprintf(stderr,"Radius Chromium: browser created id=%d popup=%d\n",browser->GetIdentifier(),browser->IsPopup());
      std::fflush(stderr);
    }
    page_->browser = browser;
    page_->pending_popup = false;
    for (auto& entry : pages) entry.second->client->ForgetPopup(page_);
    NSView* child = (NSView*)browser->GetHost()->GetWindowHandle();
    [child setFrame:[page_->view bounds]];
    [child setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    page_->observer = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (page_->closing) browser->GetHost()->CloseBrowser(true);
    else if (!page_->pending_url.empty()) browser->GetMainFrame()->LoadURL(page_->pending_url);
  }
  void ForgetPopup(Page* child) {
    for (auto found = pending_popups_.begin(); found != pending_popups_.end();) {
      if (found->second == child) found = pending_popups_.erase(found); else ++found;
    }
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    if (!page_) return;
    Trace("browser closing");
    Page* page = page_; page_ = nullptr;
    page->observer = nullptr;
    page->browser = nullptr;
    Message(page, RADIUS_CEF_CLOSED, "");
    Destroy(page);
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Default Alloy handling closes the containing NSWindow. Radius owns that
    // window, so tear down only this child view after the callback unwinds.
    // CefBrowserHostView's dealloc calls WindowDestroyed -> OnBeforeClose.
    NSView* child = (NSView*)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [child removeFromSuperview]; });
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popup_id,
      const CefString& target_url, const CefString&, WindowOpenDisposition,
      bool user_gesture, const CefPopupFeatures&, CefWindowInfo& window,
      CefRefPtr<CefClient>& client, CefBrowserSettings&,
      CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (!page_ || page_->closing || !page_->popup || (!user_gesture && !page_->popups)) return true;
    const std::string url = target_url.ToString();
    if (!url.empty() && !Allowed(url)) return true;
    Page* child = Allocate(page_->context_key);
    child->awaiting_context = false;
    child->pending_popup = true;
    child->navigated = true;
    const bool adopted = page_->popup(page_->callback_context, child, url.c_str()) != 0;
    Trace(adopted ? "popup adopted by native tab" : "popup rejected by native tab");
    if (!adopted) { Destroy(child); return true; }
    pending_popups_[popup_id] = child;
    window.SetAsChild(child->view, CefRect(0,0,800,600));
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = child->client;
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popup_id) override {
    Trace("popup creation aborted");
    auto found = pending_popups_.find(popup_id);
    if (found == pending_popups_.end()) return;
    Page* child = found->second; pending_popups_.erase(found);
    if (pages.count(child) && !child->browser) {
      Message(child, RADIUS_CEF_CLOSED, "Popup could not be created."); Destroy(child);
    }
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (!page_ || !page_->navigated) return;
    if (diagnostics && browser->IsPopup()) {
      std::fprintf(stderr,"Radius Chromium: popup title id=%d length=%zu\n",browser->GetIdentifier(),title.length());
      std::fflush(stderr);
    }
    page_->title = title.ToString();
    auto value = CefDictionaryValue::Create(); value->SetString("title", title); Emit(page_,RADIUS_CEF_STATE,value);
  }
  void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString&) override {
    if (page_ && frame->IsMain()) State(page_);
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool, bool, bool) override {
    if (page_) State(page_);
  }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (page_ && frame->IsMain()) {
      page_->navigation_failed = false; page_->title.clear();
      auto value = CefDictionaryValue::Create(); value->SetBool("navigationStart",true);
      Emit(page_,RADIUS_CEF_STATE,value);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int) override {
    if (page_ && frame->IsMain() && !page_->navigation_failed) State(page_,true);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      ErrorCode code,const CefString& error,const CefString&) override {
    if (page_ && frame->IsMain()) {
      page_->navigation_failed = true;
      if (code != ERR_ABORTED) Message(page_,RADIUS_CEF_ERROR,error.ToString());
    }
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,bool,bool) override {
    const std::string url = request->GetURL().ToString();
    if (Allowed(url) || (!frame->IsMain() &&
        (url.rfind("data:",0)==0 || url=="about:srcdoc"))) return false;
    if (page_ && frame->IsMain()) Message(page_,RADIUS_CEF_ERROR,"This Chromium adapter allows HTTP and HTTPS navigation only.");
    return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus,
      int,const CefString&) override {
    if (page_) Message(page_,RADIUS_CEF_ERROR,"The Chromium renderer stopped. Reload this page to recover.");
  }
  bool CanDownload(CefRefPtr<CefBrowser>,const CefString&,const CefString&) override {
    if (page_) Message(page_,RADIUS_CEF_NOTICE,"Downloads are not available in the development Chromium adapter. Reopen this page in WebKit to download.");
    return false;
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success,
      const void* result,size_t size) override {
    if (!page_) return;
    auto value = CefDictionaryValue::Create(); value->SetInt("id",id); value->SetBool("success",success);
    auto parsed = CefParseJSON(std::string(static_cast<const char*>(result),size),JSON_PARSER_RFC);
    if (parsed) value->SetValue("result",parsed);
    Emit(page_,RADIUS_CEF_RESULT,value);
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser>, const CefString& method,
      const void* params,size_t size) override {
    if (!page_) return;
    const std::string name = method.ToString();
    auto value = CefDictionaryValue::Create();
    if (name == "Runtime.executionContextsCleared") {
      value->SetBool("clear",true);
    } else if (name == "Runtime.executionContextCreated" ||
               name == "Runtime.executionContextDestroyed") {
      if (!params || size > 65536) return;
      auto parsed = CefParseJSON(std::string(static_cast<const char*>(params),size),JSON_PARSER_RFC);
      auto dictionary = parsed ? parsed->GetDictionary() : nullptr;
      if (!dictionary) return;
      if (name == "Runtime.executionContextCreated") {
        auto context = dictionary->GetDictionary("context");
        auto auxiliary = context ? context->GetDictionary("auxData") : nullptr;
        // Only the native Reader world is relevant. Never forward origins,
        // frame URLs, page worlds, or other DevTools event payloads.
        if (!context || context->GetString("name") != "org.radius.reader" ||
            !auxiliary || auxiliary->GetString("type") != "isolated") return;
        value->SetInt("id",context->GetInt("id"));
        value->SetString("uniqueID",context->GetString("uniqueId"));
      } else {
        value->SetBool("destroyed",true);
        value->SetInt("id",dictionary->GetInt("executionContextId"));
        value->SetString("uniqueID",dictionary->GetString("executionContextUniqueId"));
      }
    } else return;
    Emit(page_,RADIUS_CEF_READER_CONTEXT,value);
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    if (!page_) return;
    auto value = CefDictionaryValue::Create(); value->SetBool("clear",true);
    Emit(page_,RADIUS_CEF_READER_CONTEXT,value);
  }
 private:
  Page* page_;
  std::map<int,Page*> pending_popups_;
  IMPLEMENT_REFCOUNTING(Client);
};
Page::Page() { [view setWantsLayer:YES]; }
Page::~Page() { [view release]; }
void Destroy(Page* page) {
  page->client->DetachPage();
  auto context = contexts.find(page->context_key);
  if (context != contexts.end() && --context->second.pages == 0) contexts.erase(context);
  pages.erase(page);
}
Page* Allocate(const std::string& key) {
  auto value = std::make_unique<Page>(); Page* page = value.get();
  page->context_key = key; page->client = new Client(page);
  contexts.at(key).pages++;
  pages.emplace(page,std::move(value)); return page;
}

void CreateReadyPage(Page* page) {
  page->awaiting_context = false;
  CefWindowInfo window; window.SetAsChild(page->view,CefRect(0,0,800,600));
  window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  // A synchronous result is essential: CreateBrowser queues an internal task
  // whose later failure has no client callback and cannot be cancelled.
  if (!CefBrowserHost::CreateBrowserSync(window,page->client,"about:blank",settings,nullptr,
                                       contexts.at(page->context_key).value)) {
    last_error = "Chromium could not create a browser view. Reopen this tab to retry.";
    Message(page,RADIUS_CEF_ERROR,last_error);
  }
}
class ContextHandler final : public CefRequestContextHandler {
 public:
  ContextHandler(std::string key,uint64_t generation) : key_(std::move(key)),generation_(generation) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext>) override {
    const auto context = contexts.find(key_);
    // Closing all waiting tabs removes this context. A stale completion must
    // never create a browser, or initialize a replacement with the same key.
    // CEF gives callbacks fresh C++ wrappers; their pointer identity differs.
    if (stopped || context == contexts.end() || context->second.generation != generation_) return;
    Trace("request context ready");
    context->second.ready = true;
    std::vector<Page*> waiting;
    for (auto& entry : pages)
      if (entry.second->context_key == key_ && entry.second->awaiting_context) waiting.push_back(entry.first);
    for (Page* page : waiting) if (pages.count(page) && !page->closing) CreateReadyPage(page);
  }
 private:
  std::string key_;
  uint64_t generation_;
  IMPLEMENT_REFCOUNTING(ContextHandler);
};

bool EnsureDirectory(const std::string& path) {
  NSString* directory = [NSString stringWithUTF8String:path.c_str()];
  NSError* error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
      attributes:@{NSFilePosixPermissions:@0700} error:&error] ||
      ![[NSFileManager defaultManager] isWritableFileAtPath:directory]) {
    last_error = "Chromium could not create a writable website-data directory.";
    return false;
  }
  return true;
}

int Initialize(const char* package,const char* data,const char* main_bundle) {
  if (initialized) return 1;
  if (stopped) { last_error = "Restart Radius before using Chromium again."; return 0; }
  diagnostics = [[[NSProcessInfo processInfo] arguments] containsObject:@"--smoke-test"] &&
      [[[NSProcessInfo processInfo] environment] objectForKey:@"RADIUS_SMOKE_TEST_DATA"] != nil;
  if (![NSApp respondsToSelector:@selector(setHandlingSendEvent:)]) {
    last_error = "Radius application bootstrap is missing."; return 0;
  }
  class_addProtocol([NSApp class], @protocol(CefAppProtocol));
  const std::string framework = std::string(package) + "/Contents/Frameworks/Chromium Embedded Framework.framework";
  if (!cef_load_library((framework+"/Chromium Embedded Framework").c_str())) {
    last_error = "Could not load the packaged Chromium framework."; return 0;
  }
  data_root = std::string(data) + "/Chromium";
  if (!EnsureDirectory(data_root + "/Profiles")) return 0;
  CefSettings settings;
  settings.external_message_pump = true;
  settings.command_line_args_disabled = true;
  CefString(&settings.framework_dir_path) = framework;
  CefString(&settings.resources_dir_path) = framework + "/Resources";
  CefString(&settings.browser_subprocess_path) = std::string(package)+"/Contents/Frameworks/RadiusChromium Helper.app/Contents/MacOS/RadiusChromium Helper";
  CefString(&settings.main_bundle_path) = main_bundle;
  // ChromeBrowserContext requires each persistent profile to be an immediate
  // child of the user-data root; a deeper path silently falls back to OTR.
  CefString(&settings.root_cache_path) = data_root + "/Profiles";
  CefString(&settings.log_file) = data_root + "/engine.log";
  settings.log_severity = LOGSEVERITY_DISABLE; // Never persist private page URLs in a diagnostic log.
  if (diagnostics)
    settings.log_severity = LOGSEVERITY_INFO; // Only isolated CI fixture browsing.
  std::string executable = std::string(main_bundle) + "/Contents/MacOS/Radius";
  char* argv[] = {executable.data()}; CefMainArgs args(1,argv);
  engine_app = new EngineApp();
  initialized = true; // scheduling may begin inside CefInitialize
  if (!CefInitialize(args,settings,engine_app,nullptr)) {
    initialized = false; stopped = true; last_error = "CEF initialization failed; restart Radius before retrying."; return 0;
  }
  Trace("CEF initialized");
  SchedulePump(0); return 1;
}
void* Create(const char* profile,const char* private_window) {
  if (!initialized || stopped) return nullptr;
  const bool ephemeral = private_window && *private_window;
  const std::string key = ephemeral ? std::string("private:")+private_window+":"+profile : std::string("profile:")+profile;
  if (!contexts.count(key)) {
    CefRequestContextSettings settings;
    if (!ephemeral) {
      const std::string path = data_root + "/Profiles/" + profile;
      if (!EnsureDirectory(path)) return nullptr;
      CefString(&settings.cache_path) = path;
    }
    const uint64_t generation = ++next_context_generation;
    auto context = CefRequestContext::CreateContext(settings,new ContextHandler(key,generation));
    if (!context) { last_error="Chromium could not create an isolated website context."; return nullptr; }
    contexts.emplace(key,Context{context,0,false,generation});
  }
  Page* page = Allocate(key);
  if (contexts.at(key).ready) {
    CreateReadyPage(page);
    if (!page->browser) { Destroy(page); return nullptr; }
  }
  return page;
}
void* NativeView(void* opaque) { return static_cast<Page*>(opaque)->view; }
void Callbacks(void* opaque,void* context,radius_cef_event_callback event,radius_cef_popup_callback popup) {
  auto page=static_cast<Page*>(opaque); page->callback_context=context; page->event=event; page->popup=popup;
}
void Command(void* opaque,int command,const char* text,double value) {
  auto page=static_cast<Page*>(opaque); if (!pages.count(page) || page->closing) return;
  if (command==RADIUS_CEF_POPUPS) { page->popups=value!=0; return; }
  if (command==RADIUS_CEF_LOAD) {
    if (!Allowed(text ? text : "")) { Message(page,RADIUS_CEF_ERROR,"Only HTTP and HTTPS addresses are supported."); return; }
    page->navigated=true;
    page->pending_url=text;
    if (page->browser) page->browser->GetMainFrame()->LoadURL(text);
    return;
  }
  if (!page->browser) return;
  auto browser=page->browser; auto host=browser->GetHost();
  switch (command) {
    case RADIUS_CEF_RELOAD: browser->Reload(); break;
    case RADIUS_CEF_STOP: browser->StopLoad(); break;
    case RADIUS_CEF_BACK: browser->GoBack(); break;
    case RADIUS_CEF_FORWARD: browser->GoForward(); break;
    case RADIUS_CEF_FOCUS: host->SetFocus(true); break;
    case RADIUS_CEF_ZOOM: host->SetZoomLevel(std::log(value)/std::log(1.2)); break;
    case RADIUS_CEF_FIND:
      if (!text || !*text) host->StopFinding(true);
      else host->Find(text,value==0,false,true);
      break;
  }
}
void DevTools(void* opaque,int id,const char* method,const char* parameters) {
  auto page=static_cast<Page*>(opaque);
  auto value=CefParseJSON(parameters,JSON_PARSER_RFC);
  if (page->browser && !page->closing &&
      page->browser->GetHost()->ExecuteDevToolsMethod(id,method,value ? value->GetDictionary() : nullptr) != 0) return;
  auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",false);
  Emit(page,RADIUS_CEF_RESULT,response);
}
void Close(void* opaque) {
  auto page=static_cast<Page*>(opaque); if (!pages.count(page)) return;
  page->event=nullptr; page->popup=nullptr; page->callback_context=nullptr; page->closing=true;
  if (page->browser) page->browser->GetHost()->CloseBrowser(true);
  else if (!page->pending_popup) Destroy(page);
}
int Live() { return static_cast<int>(pages.size()); }
int Shutdown() {
  if (!initialized) return 1;
  if (!pages.empty()) { last_error="Chromium pages are still closing."; return 0; }
  stopped=true; CancelPump();
  contexts.clear(); CefShutdown(); engine_app=nullptr; initialized=false;
  // Never dlclose Chromium: runtime code may remain referenced by ObjC classes.
  return 1;
}
const char* Error() { return last_error.c_str(); }
const radius_cef_api api={1,Initialize,Error,Create,NativeView,Callbacks,Command,DevTools,Close,Live,Shutdown};
}
extern "C" __attribute__((visibility("default"))) const radius_cef_api* radius_cef_get_api() { return &api; }
