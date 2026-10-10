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
- (void)synchronizeBrowserWindow;
@end
@implementation RadiusChromiumHostView
- (void)synchronizeBrowserWindow {
  NSWindow* child = self.browserWindow;
  if (!child) return;
  NSWindow* parent = self.window;
  NSRect visible = self.visibleRect;
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
    SynchronizeViews();
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
class BrowserViewDelegate;
class WindowDelegate;
std::map<Page*, std::unique_ptr<Page>> pages;
std::map<int,CefRefPtr<CefBrowser>> unowned_browsers;
struct Page {
  RadiusChromiumHostView* view = [[RadiusChromiumHostView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<Client> client;
  CefRefPtr<CefBrowserView> browser_view;
  CefRefPtr<CefWindow> window;
  CefRefPtr<BrowserViewDelegate> view_delegate;
  CefRefPtr<WindowDelegate> window_delegate;
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
  bool management = false;
  bool fixture_dialog = false;
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

class Client final : public CefClient, public CefLifeSpanHandler,
                     public CefDisplayHandler, public CefLoadHandler,
                     public CefRequestHandler, public CefDownloadHandler,
                     public CefDevToolsMessageObserver, public CefCommandHandler, public CefDialogHandler {
 public:
  explicit Client(Page* page) : page_(page) {}
  void DetachPage() { page_ = nullptr; }
  Page* page() const { return page_; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  bool OnFileDialog(CefRefPtr<CefBrowser> browser,FileDialogMode mode,const CefString&,const CefString&,
      const std::vector<CefString>&,const std::vector<CefString>&,const std::vector<CefString>&,
      CefRefPtr<CefFileDialogCallback> callback) override {
    // Automated API fixture selection only. Consumer installations always use
    // Chrome's Web Store permission UI; no release file chooser is overridden.
    if (!diagnostics || !page_ || !page_->fixture_dialog || mode!=FILE_DIALOG_OPEN_FOLDER ||
        browser->GetMainFrame()->GetURL().ToString().rfind("chrome://extensions/",0)!=0) return false;
    page_->fixture_dialog=false;
    const std::string path=data_root+"/ExtensionAcceptance/current";
    if (![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:(path+"/manifest.json").c_str()]]) {
      callback->Cancel(); return true;
    }
    callback->Continue({CefString(path)}); return true;
  }
  bool OnChromeCommand(CefRefPtr<CefBrowser> browser,int id,cef_window_open_disposition_t) override {
    if (!page_) return true;
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
                               "IDC_SHOW_SIGNIN","IDC_ADD_NEW_PROFILE","IDC_SHOW_SETTINGS"})
      if (id == cef_id_for_command_id_name(command)) return true;
    return false;
  }
  bool IsChromeAppMenuItemVisible(CefRefPtr<CefBrowser>,int id) override {
    for (const char* command : {"IDC_NEW_WINDOW","IDC_NEW_INCOGNITO_WINDOW","IDC_EXIT",
                               "IDC_SHOW_SIGNIN","IDC_ADD_NEW_PROFILE","IDC_SHOW_SETTINGS"})
      if (id == cef_id_for_command_id_name(command)) return false;
    return true;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (!page_ || page_->browser) {
      // Chrome APIs which create complete extra browser windows must not
      // replace this tab's client state or escape Radius's ownership.
      unowned_browsers[browser->GetIdentifier()] = browser;
      browser->GetHost()->CloseBrowser(true);
      if (page_) Message(page_,RADIUS_CEF_NOTICE,"This extension requested a separate Chromium window. Use a Radius tab instead.");
      return;
    }
    if (diagnostics) {
      std::fprintf(stderr,"Radius Chromium: browser created id=%d popup=%d\n",browser->GetIdentifier(),browser->IsPopup());
      std::fflush(stderr);
    }
    page_->browser = browser;
    page_->pending_popup = false;
    for (auto& entry : pages) entry.second->client->ForgetPopup(page_);
    page_->observer = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (page_->closing) browser->GetHost()->CloseBrowser(true);
    else if (!page_->pending_url.empty()) browser->GetMainFrame()->LoadURL(page_->pending_url);
  }
  void ForgetPopup(Page* child) {
    for (auto found = pending_popups_.begin(); found != pending_popups_.end();) {
      if (found->second == child) found = pending_popups_.erase(found); else ++found;
    }
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (unowned_browsers.erase(browser->GetIdentifier()) != 0) return;
    if (!page_ || !page_->browser || !page_->browser->IsSame(browser)) return;
    Trace("browser closing");
    Page* page = page_; page_ = nullptr;
    page->observer = nullptr;
    page->browser = nullptr;
    Message(page, RADIUS_CEF_CLOSED, "");
    Destroy(page);
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
    // Leave parent_view empty: Views creates the intact Chrome-style popup.
    window.runtime_style = CEF_RUNTIME_STYLE_CHROME;
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
    if (!page_ || !page_->navigated || !page_->browser || !page_->browser->IsSame(browser)) return;
    if (diagnostics && browser->IsPopup()) {
      std::fprintf(stderr,"Radius Chromium: popup title id=%d length=%zu\n",browser->GetIdentifier(),title.length());
      std::fflush(stderr);
    }
    page_->title = title.ToString();
    auto value = CefDictionaryValue::Create(); value->SetString("title", title); Emit(page_,RADIUS_CEF_STATE,value);
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString&) override {
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) State(page_);
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool, bool, bool) override {
    if (page_ && page_->browser && page_->browser->IsSame(browser)) State(page_);
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      page_->view.contentHidden = NO;
      page_->navigation_failed = false; page_->title.clear();
      auto value = CefDictionaryValue::Create(); value->SetBool("navigationStart",true);
      Emit(page_,RADIUS_CEF_STATE,value);
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain() && !page_->navigation_failed) State(page_,true);
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      ErrorCode code,const CefString& error,const CefString&) override {
    if (page_ && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      page_->navigation_failed = true;
      if (code != ERR_ABORTED) {
        page_->view.contentHidden = YES;
        Message(page_,RADIUS_CEF_ERROR,error.ToString());
      }
    }
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,bool,bool) override {
    const std::string url = request->GetURL().ToString();
    if (Allowed(url) || (page_ && page_->management && url.rfind("chrome://extensions/",0)==0) || (!frame->IsMain() &&
        (url.rfind("data:",0)==0 || url=="about:srcdoc"))) return false;
    if (page_ && frame->IsMain()) Message(page_,RADIUS_CEF_ERROR,"This Chromium adapter allows HTTP and HTTPS navigation only.");
    return true;
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus,
      int,const CefString&) override {
    if (page_) Message(page_,RADIUS_CEF_ERROR,"The Chromium renderer stopped. Reload this page to recover.");
  }
  bool CanDownload(CefRefPtr<CefBrowser>,const CefString&,const CefString&) override {
    return page_ && !page_->closing && page_->event;
  }
  static bool ExtensionDownload(CefRefPtr<CefDownloadItem> item) {
    std::string name = item->GetSuggestedFileName().ToString();
    std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c) { return std::tolower(c); });
    return item->GetMimeType()=="application/x-chrome-extension" ||
        (name.size()>=4 && name.substr(name.size()-4)==".crx");
  }
  bool OnBeforeDownload(CefRefPtr<CefBrowser>,CefRefPtr<CefDownloadItem> item,
      const CefString& name,CefRefPtr<CefBeforeDownloadCallback> callback) override {
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
  void OnDownloadUpdated(CefRefPtr<CefBrowser>,CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override {
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
  std::map<int,Page*> pending_popups_;
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
    // GetChromeToolbar becomes available after the browser enters a window.
    if (auto toolbar = page_->browser_view->GetChromeToolbar()) {
      window->AddChildView(toolbar);
      window->ReorderChildView(toolbar,0);
    }
    layout->SetFlexForView(page_->browser_view,1);
    NSView* native = (NSView*)window->GetWindowHandle();
    page_->view.browserWindow = [native window];
    page_->view.browserWindow.hasShadow = NO;
    page_->view.browserWindow.excludedFromWindowsMenu = YES;
    page_->view.browserWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    [page_->view synchronizeBrowserWindow];
  }
  void OnWindowActivationChanged(CefRefPtr<CefWindow>,bool active) override {
    if (page_ && active) {
      [page_->view.window makeMainWindow];
      Message(page_,RADIUS_CEF_ACTIVATE,"");
    }
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    if (!page_) return;
    page_->view.browserWindow = nil;
    page_->window = nullptr;
  }
  bool CanClose(CefRefPtr<CefWindow>) override {
    return !page_ || !page_->browser || page_->browser->GetHost()->TryCloseBrowser();
  }
  CefSize GetPreferredSize(CefRefPtr<CefView>) override { return CefSize(800,600); }
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow>) override { return CEF_SHOW_STATE_HIDDEN; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanResize(CefRefPtr<CefWindow>) override { return false; }
  bool CanMaximize(CefRefPtr<CefWindow>) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow>) override { return false; }
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
  for (auto& entry : pages) [entry.second->view synchronizeBrowserWindow];
}
void Destroy(Page* page) {
  page->client->DetachPage();
  if (page->view_delegate) page->view_delegate->DetachPage();
  if (page->window_delegate) page->window_delegate->DetachPage();
  NSWindow* child = page->view.browserWindow;
  if (child.parentWindow) [child.parentWindow removeChildWindow:child];
  page->view.browserWindow = nil;
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
      const int command = cef_id_for_command_id_name("IDC_FOCUS_LOCATION");
      if (command >= 0) host->ExecuteChromeCommand(command,CEF_WOD_CURRENT_TAB);
      break;
    }
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
// Inspect only this process's own accessibility objects, and only in the
// isolated acceptance launch. No system AX trust or TCC permission is changed.
bool AcceptFixtureExtension(Page* page) {
  if (!diagnostics || !page->view.browserWindow) return false;
  NSWindow* chrome = page->view.browserWindow;
  for (NSWindow* window in [NSApp windows]) {
    bool owned = false;
    for (NSWindow* owner=window; owner; owner=owner.parentWindow)
      if (owner==chrome) { owned=true; break; }
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
        if ([labels containsObject:@"Cancel"]) cancel=true;
        if ([labels containsObject:@"Add extension"] && [element respondsToSelector:@selector(isAccessibilityEnabled)] &&
            [element isAccessibilityEnabled] && [element respondsToSelector:@selector(accessibilityPerformPress)]) accept=element;
      }
      if ([element respondsToSelector:@selector(accessibilityChildren)]) {
        NSArray* children=[element accessibilityChildren];
        for (id child in children) pending.push_back(child);
      }
    }
    if (fixture && cancel && accept) return [accept accessibilityPerformPress];
  }
  return false;
}
void DevTools(void* opaque,int id,const char* method,const char* parameters) {
  auto page=static_cast<Page*>(opaque);
  if (diagnostics && std::string(method)=="Radius.chooseFixtureDirectory") {
    page->fixture_dialog=true;
    auto result=CefDictionaryValue::Create(); result->SetBool("armed",true);
    auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",true);
    response->SetDictionary("result",result); Emit(page,RADIUS_CEF_RESULT,response); return;
  }
  if (diagnostics && std::string(method)=="Radius.acceptFixtureExtension") {
    auto result=CefDictionaryValue::Create(); result->SetBool("pressed",AcceptFixtureExtension(page));
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
int Shutdown() {
  if (!initialized) return 1;
  if (!pages.empty() || !unowned_browsers.empty()) { last_error="Chromium pages are still closing."; return 0; }
  stopped=true; CancelPump();
  contexts.clear(); CefShutdown(); engine_app=nullptr; initialized=false;
  // Never dlclose Chromium: runtime code may remain referenced by ObjC classes.
  return 1;
}
const char* Error() { return last_error.c_str(); }
const radius_cef_api api={2,Initialize,Error,Create,NativeView,Callbacks,Command,DevTools,Close,Live,Shutdown};
}
extern "C" __attribute__((visibility("default"))) const radius_cef_api* radius_cef_get_api() { return &api; }
