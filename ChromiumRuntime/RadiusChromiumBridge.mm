// SPDX-License-Identifier: MPL-2.0
// All entry points and browser callbacks run on the AppKit main thread.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>
#include "RadiusEngineABI.h"
#include "include/cef_app.h"
#include "include/cef_command_line.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/cef_id_mappers.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/views/cef_box_layout.h"
#include "include/wrapper/cef_library_loader.h"

// A supported Chrome-style Views window owns its NSView hierarchy. Never move
// Chrome's views into a native parent (which forces Alloy). AppKit attaches the
// intact window to Radius and aligns it with this layout anchor instead.
@interface RadiusChromiumHostView : NSView
@property(nonatomic, assign) NSWindow* browserWindow;
@property(nonatomic, assign) BOOL contentHidden;
@property(nonatomic, assign) BOOL auxiliary;
@property(nonatomic, assign) BOOL chromeStyle;
@property(nonatomic, assign) BOOL navigationChrome;
- (void)synchronizeBrowserWindow;
@end
@implementation RadiusChromiumHostView
@synthesize browserWindow;
@synthesize contentHidden;
@synthesize auxiliary;
@synthesize chromeStyle;
@synthesize navigationChrome;
- (void)synchronizeBrowserWindow {
  if (self.auxiliary) return;
  NSWindow* child = self.browserWindow;
  if (!child) return;
  NSWindow* parent = self.window;
  // On macOS 14 an unclipped NSView's visibleRect may extend beyond its own
  // bounds. The Chrome child must never cover Radius's surrounding controls.
  NSRect visible = NSIntersectionRect(self.bounds, self.visibleRect);
  NSWindow* modal = NSApp.modalWindow;
  BOOL show = !self.contentHidden && parent && parent.visible && !parent.miniaturized &&
      !self.hiddenOrHasHiddenAncestor && !NSIsEmptyRect(visible) &&
      !parent.attachedSheet && (!modal || modal == parent || modal == child);
  if (!show) {
    if (child.visible) [child orderOut:nil];
    if (child.parentWindow) [child.parentWindow removeChildWindow:child];
    return;
  }
  if (child.parentWindow != parent) {
    if (child.parentWindow) [child.parentWindow removeChildWindow:child];
    [parent addChildWindow:child ordered:NSWindowAbove];
  }
  NSRect bounds = [parent convertRectToScreen:[self convertRect:visible toView:nil]];
  if (!NSEqualRects(child.frame,bounds)) [child setFrame:bounds display:YES];
  if (!child.visible) [child orderFront:nil];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self synchronizeBrowserWindow]; }
- (void)setFrame:(NSRect)frame { [super setFrame:frame]; [self synchronizeBrowserWindow]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; [self synchronizeBrowserWindow]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder {
  if (self.browserWindow.visible) [self.browserWindow makeKeyWindow];
  return YES;
}
- (void)dealloc {
  if (self.browserWindow.parentWindow) [self.browserWindow.parentWindow removeChildWindow:self.browserWindow];
  [super dealloc];
}
@end

namespace {
void SynchronizeViews();
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
CefRefPtr<CefClient> DefaultClient();
class EngineApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                    CefRefPtr<CefCommandLine> command_line) override {
    // Radius enforces popup policy in OnBeforePopup. Chrome's earlier blocker
    // otherwise ignores Radius's allow toggle, especially in private contexts
    // where default content settings cannot be changed.
    if (process_type.empty()) command_line->AppendSwitch("disable-popup-blocking");
    if (process_type.empty() && diagnostics &&
        [[[NSProcessInfo processInfo] environment] objectForKey:@"RADIUS_SMOKE_TEST_EXTENSION_FIXTURE"]) {
      // Only isolated acceptance launches expose browser-target CDP. Chrome
      // allocates a loopback port and records it in disposable DevToolsActivePort.
      command_line->AppendSwitchWithValue("remote-debugging-port", "0");
      command_line->AppendSwitchWithValue("remote-debugging-address", "127.0.0.1");
    }
  }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return DefaultClient(); }
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
    SynchronizeViews();
    pumping = false;
    if (!pump_timer) SchedulePump(1000 / 30);
  }] retain];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSRunLoopCommonModes];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop mainRunLoop] addTimer:pump_timer forMode:NSModalPanelRunLoopMode];
}

struct Context {
  CefRefPtr<CefRequestContext> value;
  size_t pages = 0;
  bool ready = false;
  uint64_t generation = 0;
  bool retained = false;
  std::string private_window;
  std::string profile;
};
uint64_t next_context_generation = 0;
std::map<std::string, Context> contexts;
struct Page;
class Client;
class BrowserViewDelegate;
class WindowDelegate;
std::map<Page*, std::unique_ptr<Page>> pages;
std::map<int,Page*> browser_pages;
std::map<std::pair<int,int>,Page*> pending_popups;
std::map<int,CefRefPtr<CefBrowser>> unowned_browsers;
struct Page {
  RadiusChromiumHostView* view = [[RadiusChromiumHostView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<Client> client;
  CefRefPtr<CefBrowserView> browser_view;
  CefRefPtr<CefView> toolbar;
  CefRefPtr<CefWindow> window;
  CefRefPtr<BrowserViewDelegate> view_delegate;
  CefRefPtr<WindowDelegate> window_delegate;
  CefRefPtr<CefRegistration> observer;
  int browser_id = 0;
  std::string context_key;
  std::string pending_url;
  std::string title;
  bool navigation_failed = false;
  bool closing = false;
  bool navigated = false;
  bool popups = false;
  bool awaiting_context = true;
  bool pending_popup = false;
  bool management = false;
  bool navigation_chrome_visible = false;
  int focus_location_requests = 0;
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
  value->SetBool("chromeStyle",page->browser->GetHost()->GetRuntimeStyle()==CEF_RUNTIME_STYLE_CHROME);
  value->SetBool("navigationChrome",page->view.navigationChrome);
  value->SetBool("loading", page->browser->IsLoading());
  value->SetBool("canGoBack", page->browser->CanGoBack());
  value->SetBool("canGoForward", page->browser->CanGoForward());
  Emit(page, finished ? RADIUS_CEF_FINISHED : RADIUS_CEF_STATE, value);
}
bool Allowed(const std::string& url) {
  NSString* value = [NSString stringWithUTF8String:url.c_str()];
  NSURLComponents* parts = [NSURLComponents componentsWithString:value];
  NSString* scheme = [[parts scheme] lowercaseString];
  if ([scheme isEqualToString:@"chrome-extension"]) return [[parts host] length] == 32;
  if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
    return [[parts host] length] > 0 && [parts user] == nil && [parts password] == nil;
  return [scheme isEqualToString:@"blob"] || [value isEqualToString:@"about:blank"] ||
         [value hasPrefix:@"about:blank#"];
}
void Destroy(Page* page);
Page* Allocate(const std::string& key);
Page* AdoptAuxiliaryBrowser(CefRefPtr<CefBrowser> browser,Page* preferred_owner);

class Client final : public CefClient, public CefLifeSpanHandler,
                     public CefDisplayHandler, public CefLoadHandler,
                     public CefRequestHandler, public CefDownloadHandler,
                     public CefDevToolsMessageObserver, public CefCommandHandler {
 public:
  explicit Client(Page* page) : page_(page) {}
  void DetachPage() { page_ = nullptr; }
  Page* page() const { return page_; }
  Client* ForBrowser(CefRefPtr<CefBrowser> browser) const {
    auto found = browser ? browser_pages.find(browser->GetIdentifier()) : browser_pages.end();
    return found == browser_pages.end() ? nullptr : found->second->client.get();
  }
  bool HasPendingDownloads() const { return !downloads_.empty(); }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  bool OnChromeCommand(CefRefPtr<CefBrowser> browser,int id,cef_window_open_disposition_t disposition) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnChromeCommand(browser,id,disposition);
    if (!page_) return true;
    if (page_->view.auxiliary) {
      // Chrome owns these complete auxiliary windows and their tab strip.
      // Preserve their actual WebContents/tab IDs for extension browser APIs.
      for (const auto& command : {std::pair{"IDC_EXIT","quit"},
                                  std::pair{"IDC_NEW_WINDOW","newWindow"},
                                  std::pair{"IDC_NEW_INCOGNITO_WINDOW","privateWindow"},
                                  std::pair{"IDC_SHOW_DOWNLOADS","downloads"}}) {
        if (id == cef_id_for_command_id_name(command.first)) {
          Message(page_,RADIUS_CEF_BROWSER_COMMAND,command.second); return true;
        }
      }
      return false;
    }
    const struct { const char* chromium; const char* native; } commands[] = {
      {"IDC_NEW_TAB","newTab"}, {"IDC_CLOSE_TAB","closeTab"}, {"IDC_CLOSE_WINDOW","closeWindow"},
      {"IDC_NEW_WINDOW","newWindow"}, {"IDC_NEW_INCOGNITO_WINDOW","privateWindow"},
      {"IDC_EXIT","quit"}, {"IDC_FIND","find"},
      {"IDC_SHOW_DOWNLOADS","downloads"}, {"IDC_SHOW_HISTORY","history"},
      {"IDC_BOOKMARK_THIS_TAB","bookmark"}
    };
    for (const auto& command : commands) {
      if (id == cef_id_for_command_id_name(command.chromium)) {
        [page_->view.window makeKeyAndOrderFront:nil];
        Message(page_,RADIUS_CEF_BROWSER_COMMAND,command.native); return true;
      }
    }
    if (id == cef_id_for_command_id_name("IDC_MANAGE_EXTENSIONS")) {
      [page_->view.window makeKeyAndOrderFront:nil];
      Message(page_,RADIUS_CEF_BROWSER_COMMAND,"extensions"); return true;
    }
    // Radius owns windows and profiles. Its native File menu provides these.
    for (const char* command : {"IDC_NEW_WINDOW","IDC_NEW_INCOGNITO_WINDOW","IDC_EXIT",
                               "IDC_SHOW_SIGNIN","IDC_ADD_NEW_PROFILE","IDC_OPTIONS"})
      if (id == cef_id_for_command_id_name(command)) return true;
    return false;
  }
  bool IsChromeAppMenuItemVisible(CefRefPtr<CefBrowser> browser,int id) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->IsChromeAppMenuItemVisible(browser,id);
    for (const char* command : {"IDC_NEW_WINDOW","IDC_NEW_INCOGNITO_WINDOW","IDC_EXIT",
                               "IDC_SHOW_SIGNIN","IDC_ADD_NEW_PROFILE","IDC_OPTIONS"})
      if (id == cef_id_for_command_id_name(command)) return false;
    return true;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (!page_ || page_->browser) {
      if (auto child = AdoptAuxiliaryBrowser(browser,page_)) {
        child->client->OnAfterCreated(browser); return;
      }
      // Unknown contexts must never inherit another Radius profile's identity.
      unowned_browsers[browser->GetIdentifier()] = browser;
      browser->GetHost()->CloseBrowser(true);
      if (page_) Message(page_,RADIUS_CEF_NOTICE,"The Chromium window could not be associated with a Radius profile.");
      return;
    }
    if (diagnostics) {
      std::fprintf(stderr,"Radius Chromium: browser created id=%d popup=%d\n",browser->GetIdentifier(),browser->IsPopup());
      std::fflush(stderr);
    }
    page_->browser = browser;
    page_->browser_id = browser->GetIdentifier();
    browser_pages[page_->browser_id] = page_;
    page_->view.chromeStyle = browser->GetHost()->GetRuntimeStyle()==CEF_RUNTIME_STYLE_CHROME;
    auto capabilities = CefDictionaryValue::Create();
    capabilities->SetBool("chromeStyle",page_->view.chromeStyle);
    Emit(page_,RADIUS_CEF_STATE,capabilities);
    page_->pending_popup = false;
    ForgetPopup(page_);
    page_->observer = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (page_->closing) browser->GetHost()->CloseBrowser(true);
    else if (!page_->pending_url.empty()) browser->GetMainFrame()->LoadURL(page_->pending_url);
  }
  void ForgetPopup(Page* child) {
    for (auto found = pending_popups.begin(); found != pending_popups.end();) {
      if (found->second == child) found = pending_popups.erase(found); else ++found;
    }
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnBeforeClose(browser);
    if (unowned_browsers.erase(browser->GetIdentifier()) != 0) return;
    if (!page_ || !page_->browser || !page_->browser->IsSame(browser)) return;
    Trace("browser closing");
    Page* page = page_; page_ = nullptr;
    page->observer = nullptr;
    page->browser = nullptr;
    Message(page, RADIUS_CEF_CLOSED, "");
    Destroy(page);
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
      const CefString& target_url, const CefString& name, WindowOpenDisposition disposition,
      bool user_gesture, const CefPopupFeatures& features, CefWindowInfo& window,
      CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue>& extra, bool* no_javascript_access) override {
    if (auto owner = ForBrowser(browser); owner && owner != this)
      return owner->OnBeforePopup(browser,frame,popup_id,target_url,name,disposition,user_gesture,
                                  features,window,client,settings,extra,no_javascript_access);
    if (!page_ || page_->closing || !page_->popup || (!user_gesture && !page_->popups)) return true;
    const std::string url = target_url.ToString();
    if (!url.empty() && !Allowed(url)) return true;
    Page* child = Allocate(page_->context_key);
    child->awaiting_context = false;
    child->pending_popup = true;
    child->navigated = true;
    child->view.auxiliary = page_->view.auxiliary;
    const bool adopted = page_->popup(page_->callback_context, child, url.c_str()) != 0;
    Trace(adopted ? "popup adopted by native tab" : "popup rejected by native tab");
    if (!adopted) { Destroy(child); return true; }
    pending_popups[{browser->GetIdentifier(),popup_id}] = child;
    // Leave parent_view empty: Views creates the intact Chrome-style popup.
    window.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    client = child->client;
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnBeforePopupAborted(browser,popup_id);
    Trace("popup creation aborted");
    // A native auxiliary's inherited client can outlive the source Page. Keep
    // pending ownership keyed by source browser ID until creation or abortion.
    auto found = pending_popups.find({browser->GetIdentifier(),popup_id});
    if (found == pending_popups.end()) return;
    Page* child = found->second; pending_popups.erase(found);
    if (pages.count(child) && !child->browser) {
      Message(child, RADIUS_CEF_CLOSED, "Popup could not be created."); Destroy(child);
    }
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnTitleChange(browser,title);
    if (!page_ || !page_->navigated || !page_->browser || !page_->browser->IsSame(browser)) return;
    if (diagnostics && browser->IsPopup()) {
      std::fprintf(stderr,"Radius Chromium: popup title id=%d length=%zu\n",browser->GetIdentifier(),title.length());
      std::fflush(stderr);
    }
    page_->title = title.ToString();
    auto value = CefDictionaryValue::Create(); value->SetString("title", title); Emit(page_,RADIUS_CEF_STATE,value);
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnAddressChange(browser,frame,url);
    if (page_ && page_->navigated && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      // Successful same-document navigations do not call OnLoadStart.
      page_->navigation_failed = false; page_->view.contentHidden = NO;
      auto value = CefDictionaryValue::Create(); value->SetString("committedURL",url);
      Emit(page_,RADIUS_CEF_STATE,value); State(page_);
    }
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool loading, bool back, bool forward) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnLoadingStateChange(browser,loading,back,forward);
    if (page_ && page_->browser && page_->browser->IsSame(browser)) State(page_);
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnLoadStart(browser,frame,transition);
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      page_->view.contentHidden = NO;
      page_->navigation_failed = false; page_->title.clear();
      auto value = CefDictionaryValue::Create(); value->SetBool("navigationStart",true);
      // OnLoadStart runs after main-frame navigation commits. This covers
      // extension/history navigation that did not enter Radius's load command,
      // without treating earlier loading/title updates as a committed page.
      const std::string committed_url=frame->GetURL().ToString();
      if (!committed_url.empty() && committed_url!="about:blank") page_->navigated=true;
      if (page_->navigated) value->SetString("committedURL",committed_url);
      Emit(page_,RADIUS_CEF_STATE,value);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnLoadEnd(browser,frame,status);
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain() && !page_->navigation_failed) State(page_,true);
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      ErrorCode code,const CefString& error,const CefString& url) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnLoadError(browser,frame,code,error,url);
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      page_->navigation_failed = true;
      if (code != ERR_ABORTED) {
        page_->view.contentHidden = YES;
        auto value = CefDictionaryValue::Create();
        value->SetString("message",error);
        value->SetString("failedURL",url);
        Emit(page_,RADIUS_CEF_ERROR,value);
      }
    }
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,bool gesture,bool redirect) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnBeforeBrowse(browser,frame,request,gesture,redirect);
    const std::string url = request->GetURL().ToString();
    if (page_ && page_->view.auxiliary && url.rfind("chrome://",0)==0) return false;
    if (Allowed(url) || (page_ && page_->management && url.rfind("chrome://extensions/",0)==0) || (!frame->IsMain() &&
        (url.rfind("data:",0)==0 || url=="about:srcdoc"))) return false;
    if (page_ && frame->IsMain()) Message(page_,RADIUS_CEF_ERROR,"This Chromium adapter allows HTTP and HTTPS navigation only.");
    return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
      int code,const CefString& message) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnRenderProcessTerminated(browser,status,code,message);
    if (page_) Message(page_,RADIUS_CEF_ERROR,"The Chromium renderer stopped. Reload this page to recover.");
  }
  bool CanDownload(CefRefPtr<CefBrowser> browser,const CefString& url,const CefString& method) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->CanDownload(browser,url,method);
    return page_ && !page_->closing && page_->event;
  }
  static bool ExtensionDownload(CefRefPtr<CefDownloadItem> item) {
    std::string name = item->GetSuggestedFileName().ToString();
    std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c) { return std::tolower(c); });
    return item->GetMimeType()=="application/x-chrome-extension" ||
        (name.size()>=4 && name.substr(name.size()-4)==".crx");
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,CefRefPtr<CefDownloadItem> item,
      const CefString& name,CefRefPtr<CefBeforeDownloadCallback> callback) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnBeforeDownload(browser,item,name,callback);
    // Chrome owns CRX validation, the Web Store approval and installation path.
    // Retargeting this download to a SavePanel would break that install flow.
    if (ExtensionDownload(item)) { downloads_.erase(item->GetId()); return false; }
    if (!page_ || page_->closing || !page_->event) return true;
    if (page_->management) {
      Message(page_,RADIUS_CEF_NOTICE,"Open this website in a browsing tab to save files."); return true;
    }
    auto& download = downloads_[item->GetId()];
    download.before = callback; download.announced = true;
    auto value = CefDictionaryValue::Create();
    value->SetInt("id",static_cast<int>(item->GetId()));
    value->SetString("name",name); value->SetString("url",item->GetOriginalUrl());
    Emit(page_,RADIUS_CEF_DOWNLOAD_BEGIN,value);
    // The destination callback may re-enter the message loop in a save panel.
    auto found = downloads_.find(item->GetId());
    if (page_ && found != downloads_.end() && found->second.latest) {
      Emit(page_,RADIUS_CEF_DOWNLOAD_UPDATE,found->second.latest);
    }
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnDownloadUpdated(browser,item,callback);
    if (ExtensionDownload(item)) { downloads_.erase(item->GetId()); return; }
    if (!page_) { if (item->IsInProgress()) callback->Cancel(); return; }
    auto& download = downloads_[item->GetId()]; download.control = callback;
    auto value = CefDictionaryValue::Create();
    value->SetInt("id",static_cast<int>(item->GetId()));
    value->SetDouble("fraction",std::max(0,item->GetPercentComplete()) / 100.0);
    value->SetBool("complete",item->IsComplete()); value->SetBool("cancelled",item->IsCanceled());
    value->SetBool("interrupted",item->IsInterrupted());
    const bool announced = download.announced;
    if (item->IsComplete() || item->IsCanceled() || item->IsInterrupted()) downloads_.erase(item->GetId());
    else download.latest = value;
    if (announced) Emit(page_,RADIUS_CEF_DOWNLOAD_UPDATE,value);
  }
  void DownloadPath(int id,const char* path) {
    auto found = downloads_.find(id);
    if (found == downloads_.end()) return;
    auto callback = found->second.before; found->second.before = nullptr;
    if (callback && path && *path) callback->Continue(path,false);
    else if (found->second.control) found->second.control->Cancel();
  }
  void CancelDownload(int id) {
    auto found = downloads_.find(id);
    if (found == downloads_.end()) return;
    auto control = found->second.control;
    auto before = found->second.before;
    found->second.before = nullptr;
    if (control) control->Cancel();
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
  struct Download {
    CefRefPtr<CefBeforeDownloadCallback> before;
    CefRefPtr<CefDownloadItemCallback> control;
    CefRefPtr<CefDictionaryValue> latest;
    bool announced = false;
  };
  std::map<int,Download> downloads_;
  IMPLEMENT_REFCOUNTING(Client);
};
class WindowDelegate final : public CefWindowDelegate {
 public:
  explicit WindowDelegate(Page* page) : page_(page) {}
  void DetachPage() { page_ = nullptr; }
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    if (!page_) { window->Close(); return; }
    page_->window = window;
    CefBoxLayoutSettings layout_settings;
    layout_settings.horizontal = false;
    auto layout = window->SetToBoxLayout(layout_settings);
    window->AddChildView(page_->browser_view);
    // Chrome controls are attached by BrowserViewDelegate::OnWindowChanged,
    // the documented point at which GetChromeToolbar becomes available.
    layout->SetFlexForView(page_->browser_view,1);
    NSView* native = (NSView*)window->GetWindowHandle();
    page_->view.browserWindow = [native window];
    if (page_->view.auxiliary) { window->Show(); }
    else {
      page_->view.browserWindow.hasShadow = NO;
      page_->view.browserWindow.excludedFromWindowsMenu = YES;
      page_->view.browserWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
      [page_->view synchronizeBrowserWindow];
    }
  }
  void OnWindowActivationChanged(CefRefPtr<CefWindow>,bool active) override {
    if (page_ && !page_->closing && active) {
      NSWindow* owner = page_->view.window;
      // AppKit can activate a child while its former owner is closing or is
      // a sheet. Neither is eligible to become the application's main window.
      if (owner.visible && owner.canBecomeMainWindow) [owner makeMainWindow];
      Message(page_,RADIUS_CEF_ACTIVATE,"");
    }
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    if (!page_) return;
    page_->view.browserWindow = nil;
    page_->window = nullptr;
  }
  bool CanClose(CefRefPtr<CefWindow>) override {
    if (!page_ || !page_->browser) return true;
    auto host = page_->browser->GetHost();
    // Do not start mandatory Chromium close while Radius still needs download
    // acknowledgements. An already-mandatory JS close cannot safely be vetoed.
    if (!page_->closing && !host->IsReadyToBeClosed() && page_->client->HasPendingDownloads()) {
      Message(page_,RADIUS_CEF_BROWSER_COMMAND,"closeTab"); return false;
    }
    return host->TryCloseBrowser();
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(800,600); }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow>) override { return page_ && page_->view.auxiliary ? CEF_SHOW_STATE_NORMAL : CEF_SHOW_STATE_HIDDEN; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return !page_ || !page_->view.auxiliary; }
  bool CanResize(CefRefPtr<CefWindow>) override { return page_ && page_->view.auxiliary; }
  bool CanMaximize(CefRefPtr<CefWindow>) override { return page_ && page_->view.auxiliary; }
  bool CanMinimize(CefRefPtr<CefWindow>) override { return page_ && page_->view.auxiliary; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  Page* page_;
  IMPLEMENT_REFCOUNTING(WindowDelegate);
};
void HostBrowserView(Page* page,CefRefPtr<CefBrowserView> browser_view) {
  page->browser_view = browser_view;
  page->window_delegate = new WindowDelegate(page);
  CefWindow::CreateTopLevelWindow(page->window_delegate);
}
class BrowserViewDelegate final : public CefBrowserViewDelegate {
 public:
  explicit BrowserViewDelegate(Page* page) : page_(page) {}
  void DetachPage() { page_ = nullptr; }
  void OnWindowChanged(CefRefPtr<CefView> view,bool added) override {
    if (!page_) return;
    if (added && !page_->toolbar) {
      auto browser_view=view->AsBrowserView();
      auto window=view->GetWindow();
      if (browser_view && window) {
        page_->toolbar=browser_view->GetChromeToolbar();
        if (page_->toolbar) {
          window->AddChildViewAt(page_->toolbar,0);
          window->Layout();
          page_->view.navigationChrome=YES;
          Trace("Chrome toolbar attached after BrowserView entered its window");
        }
      }
    } else if (!added && page_->toolbar) {
      if (page_->window && page_->toolbar->IsAttached()) page_->window->RemoveChildView(page_->toolbar);
      page_->toolbar=nullptr;
      page_->view.navigationChrome=NO;
    }
    auto capabilities=CefDictionaryValue::Create();
    capabilities->SetBool("navigationChrome",page_->view.navigationChrome);
    Emit(page_,RADIUS_CEF_STATE,capabilities);
  }
  CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(
      CefRefPtr<CefBrowserView>,const CefBrowserSettings&,CefRefPtr<CefClient> client,bool) override {
    for (auto& entry : pages) {
      if (entry.second->client.get() == client.get()) {
        entry.second->view_delegate = new BrowserViewDelegate(entry.first);
        return entry.second->view_delegate;
      }
    }
    return nullptr;
  }
  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView>,CefRefPtr<CefBrowserView> popup,bool) override {
    auto browser = popup->GetBrowser();
    auto client = browser->GetHost()->GetClient();
    for (auto& entry : pages) {
      // Chrome's Attach path can deliver this before OnAfterCreated. The
      // original client is already assigned by OnBeforePopup and is stable.
      if (entry.second->client.get() == client.get() && (entry.second->pending_popup ||
          (entry.second->browser && entry.second->browser->IsSame(browser)))) {
        HostBrowserView(entry.first,popup); return true;
      }
    }
    // No Radius owner must never become an untracked browser window.
    browser->GetHost()->CloseBrowser(true);
    return true;
  }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NORMAL; }
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  Page* page_;
  IMPLEMENT_REFCOUNTING(BrowserViewDelegate);
};
Page::Page() { [view setWantsLayer:YES]; }
Page::~Page() { [view release]; }
void SynchronizeViews() {
  for (auto& entry : pages) {
    auto page = entry.first;
    if (page->view.auxiliary && page->browser) {
      NSView* handle = (NSView*)page->browser->GetHost()->GetWindowHandle();
      page->view.browserWindow = [handle window];
    } else [page->view synchronizeBrowserWindow];
    NSWindow* child=page->view.browserWindow;
    const bool available=page->view.navigationChrome && page->view.window && child.visible &&
        child.parentWindow==page->view.window;
    if (available!=page->navigation_chrome_visible) {
      page->navigation_chrome_visible=available;
      auto value=CefDictionaryValue::Create(); value->SetBool("navigationChromeVisible",available);
      Emit(page,RADIUS_CEF_STATE,value);
    }
  }
}
void Destroy(Page* page) {
  page->client->DetachPage();
  if (page->view_delegate) page->view_delegate->DetachPage();
  if (page->window_delegate) page->window_delegate->DetachPage();
  NSWindow* child = page->view.browserWindow;
  if (child.parentWindow) [child.parentWindow removeChildWindow:child];
  page->view.browserWindow = nil;
  browser_pages.erase(page->browser_id);
  auto context = contexts.find(page->context_key);
  if (context != contexts.end() && --context->second.pages == 0 && !context->second.retained) contexts.erase(context);
  pages.erase(page);
}
Page* Allocate(const std::string& key) {
  auto value = std::make_unique<Page>(); Page* page = value.get();
  page->context_key = key; page->client = new Client(page);
  contexts.at(key).pages++;
  pages.emplace(page,std::move(value)); return page;
}
CefRefPtr<CefClient> DefaultClient() { return new Client(nullptr); }
Page* AdoptAuxiliaryBrowser(CefRefPtr<CefBrowser> browser,Page* preferred_owner) {
  auto context = browser->GetHost()->GetRequestContext();
  auto matches = [&](Page* page) {
    if (!page || page->closing || !page->popup || !page->callback_context) return false;
    auto found = contexts.find(page->context_key);
    return found != contexts.end() && found->second.value->IsSharingWith(context);
  };
  Page* owner = matches(preferred_owner) ? preferred_owner : nullptr;
  if (!owner) {
    for (const auto& entry : pages) if (matches(entry.first)) { owner=entry.first; break; }
  }
  if (!owner) return nullptr;
  Page* child = Allocate(owner->context_key);
  child->awaiting_context=false; child->navigated=true;
  child->view.auxiliary=YES;
  NSView* handle = (NSView*)browser->GetHost()->GetWindowHandle();
  child->view.browserWindow=[handle window];
  const std::string url = browser->GetMainFrame()->GetURL().ToString();
  if (!owner->popup(owner->callback_context,child,url.c_str())) { Destroy(child); return nullptr; }
  Trace("native auxiliary Chrome browser adopted with original WebContents");
  return child;
}

void CreateReadyPage(Page* page) {
  page->awaiting_context = false;
  CefBrowserSettings settings;
  page->view_delegate = new BrowserViewDelegate(page);
  auto view = CefBrowserView::CreateBrowserView(page->client,"about:blank",settings,nullptr,
      contexts.at(page->context_key).value,page->view_delegate);
  if (!view) {
    last_error = "Chromium could not create a browser view. Reopen this tab to retry.";
    Message(page,RADIUS_CEF_ERROR,last_error);
    return;
  }
  HostBrowserView(page,view);
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
  if (ephemeral && contexts.count(key) && !contexts.at(key).retained) {
    last_error="This private profile is still closing. Retry opening the tab after it finishes.";
    return nullptr;
  }
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
    contexts.emplace(key,Context{context,0,false,generation,ephemeral,ephemeral ? private_window : "",profile});
  }
  Page* page = Allocate(key);
  if (contexts.at(key).ready) {
    CreateReadyPage(page);
    if (!page->browser_view) { Destroy(page); return nullptr; }
  }
  return page;
}
void* NativeView(void* opaque) { return static_cast<Page*>(opaque)->view; }
void Callbacks(void* opaque,void* context,radius_cef_event_callback event,radius_cef_popup_callback popup) {
  auto page=static_cast<Page*>(opaque); page->callback_context=context; page->event=event; page->popup=popup;
}
void Command(void* opaque,int command,const char* text,double value) {
  auto page=static_cast<Page*>(opaque); if (!pages.count(page) || page->closing) return;
  if (command==RADIUS_CEF_DOWNLOAD_PATH) { page->client->DownloadPath(static_cast<int>(value),text); return; }
  if (command==RADIUS_CEF_DOWNLOAD_CANCEL) { page->client->CancelDownload(static_cast<int>(value)); return; }
  if (command==RADIUS_CEF_EXTENSIONS) {
    if (page->context_key.rfind("private:",0)==0) {
      Message(page,RADIUS_CEF_NOTICE,"Install and manage extensions in a regular profile window."); return;
    }
    page->management=true; page->navigated=true; page->pending_url="chrome://extensions/";
    if (page->browser) page->browser->GetMainFrame()->LoadURL(page->pending_url);
    return;
  }
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
    case RADIUS_CEF_FOCUS_LOCATION: {
      if (page->window) page->window->Activate();
      ++page->focus_location_requests;
      // Chrome's location command rejects CEF's trusted-popup window type even
      // with an exposed toolbar. Its public default-focus implementation
      // targets the omnibox and selects its text, independent of window type.
      if (page->toolbar && page->toolbar->IsDrawn()) {
        page->toolbar->RequestFocus();
        if (diagnostics) std::fprintf(stderr,"Radius Chromium: requested Chrome toolbar location focus browser=%d\n",browser->GetIdentifier());
      }
      break;
    }
    case RADIUS_CEF_RELOAD: browser->Reload(); break;
    case RADIUS_CEF_STOP: browser->StopLoad(); break;
    case RADIUS_CEF_BACK: browser->GoBack(); break;
    case RADIUS_CEF_FORWARD: browser->GoForward(); break;
    case RADIUS_CEF_FOCUS:
      if (page->window) page->window->Activate();
      host->SetFocus(true);
      break;
    case RADIUS_CEF_ZOOM: host->SetZoomLevel(std::log(value)/std::log(1.2)); break;
    case RADIUS_CEF_FIND:
      if (!text || !*text) host->StopFinding(true);
      else host->Find(text,value==0,false,true);
      break;
  }
}
// Inspect only this process's own accessibility objects, and only in the
// isolated acceptance launch. No system AX trust or TCC permission is changed.
bool AcceptFixtureExtension(Page* page,CefRefPtr<CefDictionaryValue> details) {
  if (!diagnostics || !page->view.browserWindow) return false;
  NSWindow* chrome = page->view.browserWindow;
  auto windows=CefListValue::Create();
  auto buttons=CefListValue::Create();
  details->SetList("windows",windows); details->SetList("buttons",buttons);
  int elements=0;
  for (NSWindow* window in [NSApp windows]) {
    if (!window.visible) continue;
    bool owned = false;
    for (NSWindow* owner=window; owner; owner=owner.parentWindow ?: owner.sheetParent)
      if (owner==chrome) { owned=true; break; }
    if (windows->GetSize()<32) {
      auto item=CefDictionaryValue::Create();
      item->SetInt("number",static_cast<int>(window.windowNumber));
      item->SetInt("parent",static_cast<int>(window.parentWindow.windowNumber));
      item->SetInt("sheetParent",static_cast<int>(window.sheetParent.windowNumber));
      item->SetBool("owned",owned); item->SetBool("key",window.keyWindow);
      item->SetString("title",[window.title UTF8String] ?: "");
      windows->SetDictionary(windows->GetSize(),item);
    }
    if (!owned) continue;
    std::vector<id> pending = {window};
    std::set<const void*> visited;
    id accept = nil;
    bool fixture = false;
    bool cancel = false;
    while (!pending.empty() && visited.size()<10000) {
      id element = pending.back(); pending.pop_back();
      if (!element || !visited.insert((const void*)element).second) continue;
      NSMutableSet* labels = [NSMutableSet set];
      NSMutableString* text = [NSMutableString string];
      if ([element respondsToSelector:@selector(accessibilityLabel)]) {
        id label=[element accessibilityLabel]; if ([label isKindOfClass:[NSString class]]) { [labels addObject:label]; [text appendString:label]; }
      }
      if ([element respondsToSelector:@selector(accessibilityTitle)]) {
        id title=[element accessibilityTitle]; if ([title isKindOfClass:[NSString class]]) { [labels addObject:title]; [text appendString:title]; }
      }
      if ([element respondsToSelector:@selector(accessibilityValue)]) {
        id value=[element accessibilityValue]; if ([value isKindOfClass:[NSString class]]) { [labels addObject:value]; [text appendString:value]; }
      }
      if ([text rangeOfString:@"uBlock Origin Lite" options:NSCaseInsensitiveSearch].location!=NSNotFound) fixture=true;
      NSString* role=[element respondsToSelector:@selector(accessibilityRole)] ? [element accessibilityRole] : nil;
      if ([role isEqualToString:NSAccessibilityButtonRole]) {
        for (NSString* label in labels) if (buttons->GetSize()<64) {
          NSString* bounded=label.length>160 ? [label substringToIndex:160] : label;
          buttons->SetString(buttons->GetSize(),[bounded UTF8String]);
        }
        if ([labels containsObject:@"Cancel"]) cancel=true;
        if ([labels containsObject:@"Add extension"] && [element respondsToSelector:@selector(isAccessibilityEnabled)] &&
            [element isAccessibilityEnabled] && [element respondsToSelector:@selector(accessibilityPerformPress)]) accept=element;
      }
      if ([element respondsToSelector:@selector(accessibilityChildren)]) {
        NSArray* children=[element accessibilityChildren];
        for (id child in children) pending.push_back(child);
      }
    }
    elements+=static_cast<int>(visited.size()); details->SetInt("elements",elements);
    if (fixture) details->SetBool("fixtureSeen",true);
    if (cancel) details->SetBool("cancelSeen",true);
    if (fixture && cancel && accept) return [accept accessibilityPerformPress];
  }
  return false;
}
void DevTools(void* opaque,int id,const char* method,const char* parameters) {
  auto page=static_cast<Page*>(opaque);
  if (diagnostics && std::string(method)=="Radius.chromeHostState") {
    auto result=CefDictionaryValue::Create();
    result->SetBool("toolbarPresent",page->toolbar!=nullptr);
    if (page->toolbar) {
      const auto bounds=page->toolbar->GetBounds();
      result->SetInt("toolbarWidth",bounds.width); result->SetInt("toolbarHeight",bounds.height);
      result->SetBool("toolbarVisible",page->toolbar->IsVisible());
      result->SetBool("toolbarDrawn",page->toolbar->IsDrawn());
    }
    result->SetBool("windowVisible",page->window && page->window->IsVisible());
    result->SetBool("windowActive",page->window && page->window->IsActive());
    result->SetInt("focusLocationRequests",page->focus_location_requests);
    auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",true);
    response->SetDictionary("result",result); Emit(page,RADIUS_CEF_RESULT,response); return;
  }
  if (diagnostics && std::string(method)=="Radius.acceptFixtureExtension") {
    auto result=CefDictionaryValue::Create(); result->SetBool("pressed",AcceptFixtureExtension(page,result));
    auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",true);
    response->SetDictionary("result",result); Emit(page,RADIUS_CEF_RESULT,response); return;
  }
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
int Live() { return static_cast<int>(pages.size() + unowned_browsers.size()); }
void ReleasePrivateContexts(const char* private_window,const char* profile) {
  const std::string window_id=private_window ? private_window : "";
  const std::string profile_id=profile ? profile : "";
  if (window_id.empty() && profile_id.empty()) return;
  for (auto entry=contexts.begin(); entry!=contexts.end();) {
    auto& context=entry->second;
    if (!context.private_window.empty() &&
        (window_id.empty() || context.private_window==window_id) &&
        (profile_id.empty() || context.profile==profile_id)) {
      context.retained=false;
      if (context.pages==0) { entry=contexts.erase(entry); continue; }
    }
    ++entry;
  }
}
int Shutdown() {
  if (!initialized) return 1;
  if (!pages.empty() || !unowned_browsers.empty()) { last_error="Chromium pages are still closing."; return 0; }
  stopped=true; CancelPump();
  contexts.clear(); CefShutdown(); engine_app=nullptr; initialized=false;
  // Never dlclose Chromium: runtime code may remain referenced by ObjC classes.
  return 1;
}
const char* Error() { return last_error.c_str(); }
const radius_cef_api api={3,Initialize,Error,Create,NativeView,Callbacks,Command,DevTools,Close,Live,Shutdown,ReleasePrivateContexts};
}
extern "C" __attribute__((visibility("default"))) const radius_cef_api* radius_cef_get_api() { return &api; }
