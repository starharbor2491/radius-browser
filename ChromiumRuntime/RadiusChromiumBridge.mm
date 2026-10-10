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
#include "include/wrapper/cef_library_loader.h"

// A normal Chrome window owns its native view hierarchy and inner tab strip.
// Never provide parent_view (which forces Alloy), or move Chrome views. AppKit
// attaches the intact window to Radius and aligns it with this layout anchor.
@interface RadiusChromiumHostView : NSView
@property(nonatomic, retain) NSWindow* browserWindow;
@property(nonatomic, assign) BOOL contentHidden;
@property(nonatomic, assign) BOOL auxiliary;
@property(nonatomic, assign) BOOL chromeStyle;
@property(nonatomic, assign) BOOL navigationChrome;
@property(nonatomic, assign) BOOL activeContentKnown;
- (void)synchronizeBrowserWindow;
@end
@implementation RadiusChromiumHostView
@synthesize browserWindow;
@synthesize contentHidden;
@synthesize auxiliary;
@synthesize chromeStyle;
@synthesize navigationChrome;
@synthesize activeContentKnown;
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
  [browserWindow release];
  [super dealloc];
}
@end

namespace {
void SynchronizeViews();
bool initialized = false;
bool stopped = false;
bool final_quit_frozen = false;
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
std::map<Page*, std::unique_ptr<Page>> pages;
std::map<int,Page*> browser_pages;
std::map<int,CefRefPtr<CefBrowser>> unowned_browsers;
struct Page {
  RadiusChromiumHostView* view = [[RadiusChromiumHostView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<Client> client;
  CefRefPtr<CefRegistration> observer;
  int browser_id = 0;
  Page* group = nullptr;
  Page* active = nullptr;
  uint64_t generation = 0;
  bool close_announced = false;
  bool browser_created = false;
  bool admission_closed = false;
  bool awaiting_window = false;
  bool creating = false;
  bool restoring = false;
  bool awaiting_restore_browser = false;
  bool restore_failed = false;
  double restore_deadline = 0;
  std::vector<std::string> restore_urls;
  CefRefPtr<CefBrowser> restore_selection;
  std::string failure_message;
  std::string failed_url;
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
  double published_zoom_level = 0;
  bool zoom_published = false;
  void* callback_context = nullptr;
  radius_cef_event_callback event = nullptr;
  radius_cef_popup_callback popup = nullptr;
  Page();
  ~Page();
};

uint64_t next_page_generation = 0;
int next_devtools_id = 1;
Page* querying_group = nullptr;
Page* queried_page = nullptr;
int query_command=0;
bool reconciling_windows=false;
Page* Group(Page* page) { return page->group ? page->group : page; }
bool RefreshActive(Page* group);
void SetActive(Page* page);
void FinishEmptyGroup(Page* group);
void ReconcileWindows();
std::vector<Page*> Members(Page* group) {
  std::vector<Page*> result;
  for (auto& entry : pages)
    if (Group(entry.first)==group) result.push_back(entry.first);
  std::sort(result.begin(),result.end(),[](Page* a,Page* b) { return a->generation<b->generation; });
  return result;
}
Page* Active(Page* group) {
  group=Group(group);
  if (group->active && pages.count(group->active) &&
      Group(group->active)==group && group->active->browser) return group->active;
  for (Page* member : Members(group)) if (member->browser) return member;
  return nullptr;
}
void EmitOwned(Page* page,int event,CefRefPtr<CefDictionaryValue> value) {
  if (!page || !pages.count(page) || !page->event) return;
  auto wrapper=CefValue::Create(); wrapper->SetDictionary(value);
  std::string json=CefWriteJSON(wrapper,JSON_WRITER_DEFAULT).ToString();
  page->event(page->callback_context,event,json.c_str());
}
void Emit(Page* page, int event, CefRefPtr<CefDictionaryValue> value) {
  Page* owner=Group(page);
  if (Active(owner) && page!=Active(owner) && (event==RADIUS_CEF_STATE ||
      event==RADIUS_CEF_FINISHED || event==RADIUS_CEF_ERROR ||
      event==RADIUS_CEF_READER_CONTEXT)) return;
  EmitOwned(owner,event,value);
}
void Message(Page* page, int event, const std::string& message) {
  auto value = CefDictionaryValue::Create(); value->SetString("message", message); Emit(page, event, value);
}
void State(Page* page, bool finished = false) {
  if (page!=Active(Group(page))) { if (auto active=Active(Group(page))) State(active); return; }
  if (!page->browser || !page->navigated) return;
  auto value = CefDictionaryValue::Create();
  value->SetString("url", page->browser->GetMainFrame()->GetURL());
  value->SetString("title",page->title);
  value->SetBool("chromeStyle",page->browser->GetHost()->GetRuntimeStyle()==CEF_RUNTIME_STYLE_CHROME);
  value->SetBool("navigationChrome",Group(page)->view.navigationChrome);
  value->SetBool("loading", page->browser->IsLoading());
  value->SetBool("canGoBack", page->browser->CanGoBack());
  value->SetBool("canGoForward", page->browser->CanGoForward());
  page->published_zoom_level=page->browser->GetHost()->GetZoomLevel(); page->zoom_published=true;
  value->SetDouble("zoom",std::pow(1.2,page->published_zoom_level));
  auto inner=CefListValue::Create();
  auto group=Group(page);
  for (Page* member : Members(group)) {
    if (!member->browser) continue;
    auto item=CefDictionaryValue::Create();
    item->SetInt("id",member->browser_id);
    std::string address=member->failed_url.empty() ? member->browser->GetMainFrame()->GetURL().ToString() : member->failed_url;
    item->SetString("url",address.size()<=8192 ? address : "");
    item->SetString("title",member->title);
    item->SetBool("selected",member==Active(group));
    inner->SetDictionary(inner->GetSize(),item);
  }
  value->SetList("innerPages",inner);
  value->SetBool("restoring",group->restoring);
  Emit(page, finished ? RADIUS_CEF_FINISHED : RADIUS_CEF_STATE, value);
}
std::string BoundedTitle(const CefString& title) {
  // Count Unicode scalars, not grapheme clusters: a single visible character
  // can contain unbounded combining marks. At most 512 scalars / 2048 UTF-8 bytes.
  const auto* characters=reinterpret_cast<const unichar*>(title.c_str());
  const size_t length=title.length();
  size_t end=0;
  for (size_t count=0; count<512 && end<length; ++count) {
    const unichar first=characters[end++];
    if (first>=0xD800 && first<=0xDBFF && end<length &&
        characters[end]>=0xDC00 && characters[end]<=0xDFFF) ++end;
  }
  NSString* bounded=[NSString stringWithCharacters:characters length:end];
  return [bounded UTF8String] ?: "";
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
                     public CefDevToolsMessageObserver, public CefCommandHandler, public CefFocusHandler {
 public:
  explicit Client(Page* page) : page_(page) {}
  void SetPopupOwner(Page* owner) { popup_owner_=owner; popup_owner_generation_=owner->generation; }
  void DetachPage() { page_ = nullptr; }
  void AttachPage(Page* page) { page_ = page; }
  Page* page() const { return page_; }
  Client* ForBrowser(CefRefPtr<CefBrowser> browser) const {
    auto found = browser ? browser_pages.find(browser->GetIdentifier()) : browser_pages.end();
    if (found!=browser_pages.end() && found->second->awaiting_window && !reconciling_windows) {
      ReconcileWindows();
      found=browser_pages.find(browser->GetIdentifier());
    }
    return found == browser_pages.end() ? nullptr : found->second->client.get();
  }
  bool HasPendingDownloads() const { return !downloads_.empty(); }
  bool HasDownloadsFor(Page* owner) const {
    for (const auto& item : downloads_) if (item.second.owner==owner) return true;
    return false;
  }
  bool HasDownload(int id,Page* owner) const {
    auto found=downloads_.find(id);
    return found!=downloads_.end() && found->second.owner==owner;
  }
  void CancelNativeDownloads(Page* owner) {
    std::vector<CefRefPtr<CefDownloadItemCallback>> callbacks;
    for (const auto& item : downloads_) if ((item.second.extension || !item.second.announced) && item.second.owner==owner && item.second.control) callbacks.push_back(item.second.control);
    for (const auto& callback : callbacks) callback->Cancel();
  }
  void ExecuteRequest(Page* owner,int id,const char* method,CefRefPtr<CefDictionaryValue> params) {
    const int native_id=++next_devtools_id;
    requests_[native_id]={owner,owner->generation,id};
    if (page_ && page_->browser &&
        page_->browser->GetHost()->ExecuteDevToolsMethod(native_id,method,params)!=0) return;
    CompleteRequest(native_id,false,nullptr,0);
  }
  void CompleteRequest(int native_id,bool success,const void* result,size_t size) {
    auto found=requests_.find(native_id);
    if (found==requests_.end()) return;
    auto request=found->second; requests_.erase(found);
    if (!pages.count(request.owner) || request.owner->generation!=request.generation) return;
    auto value=CefDictionaryValue::Create(); value->SetInt("id",request.id); value->SetBool("success",success);
    if (result && size) {
      auto parsed=CefParseJSON(std::string(static_cast<const char*>(result),size),JSON_PARSER_RFC);
      if (parsed) value->SetValue("result",parsed);
    }
    EmitOwned(request.owner,RADIUS_CEF_RESULT,value);
  }
  void FailRequests() {
    while (!requests_.empty()) CompleteRequest(requests_.begin()->first,false,nullptr,0);
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
    if (auto client=ForBrowser(browser); client && client!=this) return client->OnGotFocus(browser);
    if (!page_) return;
    auto owner=Group(page_);
    RefreshActive(owner);
    if (owner->view.browserWindow.keyWindow) Message(page_,RADIUS_CEF_ACTIVATE,"");
  }
  bool OnChromeCommand(CefRefPtr<CefBrowser> browser,int id,cef_window_open_disposition_t disposition) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnChromeCommand(browser,id,disposition);
    if (!page_ || !page_->browser || !page_->browser->IsSame(browser)) return true;
    auto owner=Group(page_);
    // The public command callback receives the Browser's active WebContents.
    // Intercept this query before Chrome performs any focus or selection action.
    if (querying_group && id==query_command) {
      if (owner==querying_group) queried_page=page_;
      return true;
    }
    if (final_quit_frozen) return true;
    SetActive(page_);
    const struct { const char* chromium; const char* native; } commands[] = {
      {"IDC_NEW_WINDOW","newWindow"}, {"IDC_NEW_INCOGNITO_WINDOW","privateWindow"},
      {"IDC_EXIT","quit"}, {"IDC_SHOW_DOWNLOADS","downloads"}
    };
    for (const auto& command : commands) {
      if (id == cef_id_for_command_id_name(command.chromium)) {
        Message(page_,RADIUS_CEF_BROWSER_COMMAND,command.native); return true;
      }
    }
    // Chrome owns its tab strip, tab actions, extension toolbar and window
    // semantics. Radius retains profile isolation and application Settings.
    for (const char* command : {"IDC_SHOW_SIGNIN","IDC_ADD_NEW_PROFILE","IDC_OPTIONS"})
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
    if (!page_ || page_->browser_created) {
      Page* preferred=page_ ? Group(page_) : popup_owner_;
      if (popup_owner_ && (!pages.count(popup_owner_) || popup_owner_->generation!=popup_owner_generation_ || popup_owner_->closing || popup_owner_->admission_closed)) preferred=nullptr;
      if (!popup_owner_ || preferred) if (auto child = AdoptAuxiliaryBrowser(browser,preferred)) {
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
    page_->browser = browser; page_->browser_created=true;
    page_->browser_id = browser->GetIdentifier();
    browser_pages[page_->browser_id] = page_;
    auto owner=Group(page_);
    owner->view.chromeStyle = browser->GetHost()->GetRuntimeStyle()==CEF_RUNTIME_STYLE_CHROME;
    owner->view.navigationChrome=YES;
    NSView* handle=(NSView*)browser->GetHost()->GetWindowHandle();
    if (page_==owner) owner->view.browserWindow=[handle window];
    if (!owner->view.auxiliary) {
      owner->view.browserWindow.hasShadow=NO;
      owner->view.browserWindow.excludedFromWindowsMenu=YES;
      owner->view.browserWindow.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary;
      [owner->view synchronizeBrowserWindow];
    }
    if (!owner->active) owner->active=page_;
    auto capabilities = CefDictionaryValue::Create();
    capabilities->SetBool("chromeStyle",owner->view.chromeStyle);
    capabilities->SetBool("navigationChrome",owner->view.navigationChrome);
    Emit(page_,RADIUS_CEF_STATE,capabilities);
    page_->pending_popup = false;
    page_->observer = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (owner->restoring && owner->awaiting_restore_browser && !owner->restore_urls.empty()) {
      page_->pending_url=owner->restore_urls.front();
      owner->restore_urls.erase(owner->restore_urls.begin());
      owner->awaiting_restore_browser=false; page_->navigated=true;
    }
    if (owner->closing) browser->GetHost()->CloseBrowser(true);
    else if (!page_->pending_url.empty()) browser->GetMainFrame()->LoadURL(page_->pending_url);
    if (auto active=Active(owner)) State(active);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnBeforeClose(browser);
    if (unowned_browsers.erase(browser->GetIdentifier()) != 0) return;
    if (!page_ || !page_->browser || !page_->browser->IsSame(browser)) return;
    CefRefPtr<Client> keep_alive=this;
    Trace("inner Chrome browser closing");
    Page* member=page_; Page* owner=Group(member);
    // CEF stops download notifications when the originating WebContents dies,
    // although its writer may continue. Do not wait for an impossible callback
    // or report cancellation as confirmed. Swift retains staging until shutdown.
    FailRequests();
    auto abandoned=std::move(downloads_);
    downloads_.clear();
    std::map<Page*,uint64_t> abandoned_owners;
    for (const auto& entry : abandoned) if (entry.second.owner && pages.count(entry.second.owner))
      abandoned_owners[entry.second.owner]=entry.second.owner->generation;
    member->observer=nullptr; member->browser=nullptr;
    for (const auto& entry : abandoned) {
      const auto& download=entry.second;
      if (download.announced && pages.count(download.owner) &&
          abandoned_owners[download.owner]==download.owner->generation) {
        auto value=CefDictionaryValue::Create();
        value->SetInt("id",entry.first); value->SetBool("ownerClosed",true);
        EmitOwned(download.owner,RADIUS_CEF_DOWNLOAD_UPDATE,value);
      }
      if (download.control) download.control->Cancel();
    }
    if (owner->active==member) owner->active=nullptr;
    for (const auto& entry : abandoned_owners)
      if (entry.first!=owner && pages.count(entry.first) && entry.first->generation==entry.second) FinishEmptyGroup(entry.first);
    if (!pages.count(member) || !pages.count(owner)) return;
    if (member!=owner && !HasPendingDownloads()) Destroy(member);
    RefreshActive(owner);
    if (auto active=Active(owner)) State(active);
    FinishEmptyGroup(owner);
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
      const CefString& target_url, const CefString& name, WindowOpenDisposition disposition,
      bool user_gesture, const CefPopupFeatures& features, CefWindowInfo& window,
      CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
      CefRefPtr<CefDictionaryValue>& extra, bool* no_javascript_access) override {
    if (auto owner = ForBrowser(browser); owner && owner != this)
      return owner->OnBeforePopup(browser,frame,popup_id,target_url,name,disposition,user_gesture,
                                  features,window,client,settings,extra,no_javascript_access);
    if (!page_ || Group(page_)->closing || Group(page_)->admission_closed || !Group(page_)->popup || (!user_gesture && !Group(page_)->popups)) return true;
    const std::string url = target_url.ToString();
    if (!url.empty() && !Allowed(url)) return true;
    auto child=new Client(nullptr);
    child->SetPopupOwner(Group(page_));
    window.runtime_style=CEF_RUNTIME_STYLE_CHROME;
    client=child;
    // Preserve Chrome's disposition, opener and original WebContents. When
    // Chrome inserts the tab, OnAfterCreated associates its actual native
    // window with the existing pane or an independently owned auxiliary.
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int) override {}
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnTitleChange(browser,title);
    if (!page_ || !page_->navigated || !page_->browser || !page_->browser->IsSame(browser)) return;
    if (diagnostics && browser->IsPopup()) {
      std::fprintf(stderr,"Radius Chromium: popup title id=%d length=%zu\n",browser->GetIdentifier(),title.length());
      std::fflush(stderr);
    }
    page_->title = BoundedTitle(title);
    State(page_);
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnAddressChange(browser,frame,url);
    if (page_ && page_->navigated && page_->browser && page_->browser->IsSame(browser) && frame->IsMain()) {
      // Successful same-document navigations do not call OnLoadStart.
      page_->navigation_failed = false;
      page_->failure_message.clear(); page_->failed_url.clear();
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
      page_->navigation_failed = false; page_->title.clear();
      page_->failure_message.clear(); page_->failed_url.clear();
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
        // Keep the normal Chrome tab strip available on a failed page.
        page_->failure_message=error.ToString(); page_->failed_url=url.ToString();
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
    if (page_ && url.rfind("chrome://",0)==0) return false;
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
    return !final_quit_frozen && page_ && !page_->awaiting_window && !Group(page_)->closing && !Group(page_)->admission_closed && Group(page_)->event;
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
    CefRefPtr<Client> keep_alive=this;
    if (page_ && (final_quit_frozen || Group(page_)->closing || Group(page_)->admission_closed)) {
      auto found=downloads_.find(item->GetId());
      auto control=found!=downloads_.end() ? found->second.control : nullptr;
      if (control) control->Cancel();
      return true;
    }
    if (ExtensionDownload(item)) {
      if (!page_) return true;
      auto& download=downloads_[item->GetId()];
      download.owner=Group(page_); download.extension=true;
      // Keep cancellation/terminal ownership, while Chrome alone selects the
      // CRX destination and performs its signature and permission checks.
      return false;
    }
    if (!page_ || page_->awaiting_window || Group(page_)->closing || Group(page_)->admission_closed || !Group(page_)->event) return true;
    if (Group(page_)->management) {
      Message(page_,RADIUS_CEF_NOTICE,"Open this website in a browsing tab to save files."); return true;
    }
    auto& download = downloads_[item->GetId()];
    download.before = callback; download.announced = true; download.owner=Group(page_);
    auto value = CefDictionaryValue::Create();
    value->SetInt("id",static_cast<int>(item->GetId()));
    value->SetString("name",name); value->SetString("url",item->GetOriginalUrl());
    Emit(page_,RADIUS_CEF_DOWNLOAD_BEGIN,value);
    // The destination callback may re-enter the message loop in a save panel.
    auto found = downloads_.find(item->GetId());
    if (page_ && found != downloads_.end() && found->second.latest) {
      EmitOwned(found->second.owner,RADIUS_CEF_DOWNLOAD_UPDATE,found->second.latest);
    }
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override {
    if (auto client = ForBrowser(browser); client && client != this) return client->OnDownloadUpdated(browser,item,callback);
    if (!page_ || !page_->browser) { if (item->IsInProgress()) callback->Cancel(); return; }
    CefRefPtr<Client> keep_alive=this;
    auto& download = downloads_[item->GetId()]; download.control = callback;
    if (!download.owner) download.owner=Group(page_);
    if (ExtensionDownload(item)) { download.extension=true; if (!download.owner) download.owner=Group(page_); }
    const bool cancel_extension=(download.extension || !download.announced) && item->IsInProgress() && (Group(page_)->closing || Group(page_)->admission_closed);
    auto value = CefDictionaryValue::Create();
    value->SetInt("id",static_cast<int>(item->GetId()));
    value->SetDouble("fraction",std::max(0,item->GetPercentComplete()) / 100.0);
    value->SetBool("complete",item->IsComplete()); value->SetBool("cancelled",item->IsCanceled());
    value->SetBool("interrupted",item->IsInterrupted());
    const bool announced = download.announced;
    Page* download_owner=download.owner;
    if (item->IsComplete() || item->IsCanceled() || item->IsInterrupted()) downloads_.erase(item->GetId());
    else download.latest = value;
    if (announced) EmitOwned(download_owner,RADIUS_CEF_DOWNLOAD_UPDATE,value);
    if (page_ && !page_->browser && downloads_.empty()) {
      Page* member=page_; Page* owner=Group(member);
      if (member!=owner) Destroy(member);
      FinishEmptyGroup(owner);
    }
    if (download_owner && pages.count(download_owner)) FinishEmptyGroup(download_owner);
    if (cancel_extension) callback->Cancel();
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
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,int id,bool success,
      const void* result,size_t size) override {
    if (auto client=ForBrowser(browser); client && client!=this) return client->OnDevToolsMethodResult(browser,id,success,result,size);
    CompleteRequest(id,success,result,size);
  }
  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
      const void* params,size_t size) override {
    if (auto client=ForBrowser(browser); client && client!=this) return client->OnDevToolsEvent(browser,method,params,size);
    if (!page_ || page_!=Active(Group(page_))) return;
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
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override {
    if (auto client=ForBrowser(browser); client && client!=this) return client->OnDevToolsAgentDetached(browser);
    if (!page_) return;
    FailRequests();
    auto value = CefDictionaryValue::Create(); value->SetBool("clear",true);
    Emit(page_,RADIUS_CEF_READER_CONTEXT,value);
  }
 private:
  Page* page_;
  Page* popup_owner_ = nullptr;
  uint64_t popup_owner_generation_ = 0;
  struct Request { Page* owner; uint64_t generation; int id; };
  std::map<int,Request> requests_;
  struct Download {
    Page* owner=nullptr;
    CefRefPtr<CefBeforeDownloadCallback> before;
    CefRefPtr<CefDownloadItemCallback> control;
    CefRefPtr<CefDictionaryValue> latest;
    bool announced = false;
    bool extension = false;
  };
  std::map<int,Download> downloads_;
  IMPLEMENT_REFCOUNTING(Client);
};
// A normal Chrome Browser owns its complete native window, including the
// extension toolbar. CEF Views deliberately creates TYPE_POPUP and is unsuitable
// for browser-level extension APIs such as action.openPopup.
Page::Page() { [view setWantsLayer:YES]; generation=++next_page_generation; group=this; }
Page::~Page() { [view release]; }
void SetActive(Page* page) {
  auto owner=Group(page);
  if (owner->active==page) return;
  owner->active=page;
  auto value=CefDictionaryValue::Create();
  value->SetBool("activeContentChanged",true);
  if (page->browser && page->navigated)
    value->SetString("committedURL",page->browser->GetMainFrame()->GetURL());
  Emit(page,RADIUS_CEF_STATE,value);
  auto clear=CefDictionaryValue::Create(); clear->SetBool("clear",true);
  Emit(page,RADIUS_CEF_READER_CONTEXT,clear);
  if (!page->failure_message.empty()) {
    auto error=CefDictionaryValue::Create();
    error->SetString("message",page->failure_message); error->SetString("failedURL",page->failed_url);
    Emit(page,RADIUS_CEF_ERROR,error);
  }
  State(page);
}
bool RefreshActive(Page* owner) {
  if (!pages.count(owner) || Group(owner)!=owner || owner->closing || querying_group) return false;
  owner->view.activeContentKnown=NO;
  Page* member=Active(owner);
  if (!member) { owner->active=nullptr; return false; }
  // The focus command is disabled in fullscreen; Reload remains available.
  // Both reach the same public callback before their action, which this query
  // consumes. A window with no enabled command must never use a stale target.
  int command=0;
  for (const char* name : {"IDC_FOCUS_WEB_CONTENTS_PANE","IDC_RELOAD"}) {
    const int candidate=cef_id_for_command_id_name(name);
    if (member->browser->GetHost()->CanExecuteChromeCommand(candidate)) { command=candidate; break; }
  }
  if (!command) return false;
  querying_group=owner; queried_page=nullptr; query_command=command;
  member->browser->GetHost()->ExecuteChromeCommand(command,CEF_WOD_CURRENT_TAB);
  Page* selected=queried_page;
  querying_group=nullptr; queried_page=nullptr; query_command=0;
  if (!selected || !pages.count(selected) || Group(selected)!=owner || !selected->browser) return false;
  owner->view.activeContentKnown=YES;
  SetActive(selected); return true;
}
void FinishEmptyGroup(Page* owner) {
  if (!owner || !pages.count(owner) || Group(owner)!=owner || owner->creating || owner->awaiting_context || owner->pending_popup) return;
  for (Page* member : Members(owner)) if (member->browser) return;
  owner->view.browserWindow=nil;
  bool downloads=false;
  for (const auto& entry : pages)
    if (entry.first->client->HasDownloadsFor(owner) ||
        (Group(entry.first)==owner && entry.first->client->HasPendingDownloads())) downloads=true;
  if (downloads) {
    if (!owner->closing && !owner->close_announced) {
      owner->close_announced=true;
      Message(owner,RADIUS_CEF_BROWSER_COMMAND,"closeTab");
    }
    return;
  }
  auto members=Members(owner);
  Message(owner,RADIUS_CEF_CLOSED,"");
  for (Page* member : members) if (member!=owner && pages.count(member)) Destroy(member);
  if (pages.count(owner)) Destroy(owner);
}
void RestoreInnerPages(Page* owner) {
  if (!owner->restoring || owner->restore_failed || owner->closing) return;
  if (CFAbsoluteTimeGetCurrent()>owner->restore_deadline) {
    owner->restore_failed=true;
    auto error=CefDictionaryValue::Create();
    error->SetString("message","Chromium could not restore every saved tab. Reopen this pane to retry; its saved tabs have been retained.");
    EmitOwned(owner,RADIUS_CEF_ERROR,error); return;
  }
  auto member=Active(owner);
  if (!member || !member->browser) return;
  if (!owner->restore_selection) {
    if (owner->restore_urls.empty()) return;
    owner->restore_selection=member->browser;
    member->navigated=true;
    member->browser->GetMainFrame()->LoadURL(owner->restore_urls.front());
    owner->restore_urls.erase(owner->restore_urls.begin());
  }
  if (owner->awaiting_restore_browser) return;
  if (!owner->restore_urls.empty()) {
    const int command=cef_id_for_command_id_name("IDC_NEW_TAB");
    if (!member->browser->GetHost()->CanExecuteChromeCommand(command)) return;
    owner->awaiting_restore_browser=true;
    member->browser->GetHost()->ExecuteChromeCommand(command,CEF_WOD_CURRENT_TAB);
    return;
  }
  owner->restore_selection->GetHost()->SetFocus(true);
  owner->restore_selection=nullptr; owner->restoring=false;
  RefreshActive(owner);
  if (auto active=Active(owner)) State(active);
}
void SynchronizeViews() {
  ReconcileWindows();
  std::vector<Page*> owners;
  for (auto& entry : pages) if (Group(entry.first)==entry.first) owners.push_back(entry.first);
  for (Page* page : owners) {
    if (!pages.count(page)) continue;
    const bool active_known=RefreshActive(page);
    if (active_known) if (auto active=Active(page); active && active->browser &&
        (!active->zoom_published || std::abs(active->published_zoom_level-active->browser->GetHost()->GetZoomLevel())>0.00001)) State(active);
    RestoreInnerPages(page);
    if (!pages.count(page)) continue;
    if (!page->view.auxiliary) [page->view synchronizeBrowserWindow];
    NSWindow* child=page->view.browserWindow;
    const bool available=page->view.navigationChrome && page->view.window && child.visible &&
        child.parentWindow==page->view.window;
    if (available!=page->navigation_chrome_visible) {
      page->navigation_chrome_visible=available;
      auto value=CefDictionaryValue::Create(); value->SetBool("navigationChromeVisible",available);
      EmitOwned(page,RADIUS_CEF_STATE,value);
    }
  }
}
void Destroy(Page* page) {
  page->client->DetachPage();
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
  if (final_quit_frozen) return nullptr;
  auto context=browser->GetHost()->GetRequestContext();
  NSView* handle=(NSView*)browser->GetHost()->GetWindowHandle();
  NSWindow* window=[handle window];
  auto matches=[&](Page* owner) {
    if (!owner || Group(owner)!=owner || owner->closing || owner->admission_closed || !owner->popup || !owner->callback_context) return false;
    auto found=contexts.find(owner->context_key);
    return found!=contexts.end() && found->second.value->IsSharingWith(context);
  };
  if (preferred_owner && (!pages.count(preferred_owner) || preferred_owner->closing || preferred_owner->admission_closed)) return nullptr;
  for (auto& entry : pages) {
    Page* owner=entry.first;
    if (window && Group(owner)==owner && owner->view.browserWindow==window && (owner->closing || owner->admission_closed)) return nullptr;
    if (window && matches(owner) && owner->view.browserWindow==window) {
      size_t count=0; for (Page* member : Members(owner)) if (member->browser) ++count;
      if (count>=200) { Message(owner,RADIUS_CEF_NOTICE,"A Chromium pane supports up to 200 tabs."); return nullptr; }
      Page* member=Allocate(owner->context_key);
      member->group=owner; member->awaiting_context=false; member->navigated=true;
      Trace("Chrome inner tab adopted without changing tab or window identity");
      return member;
    }
  }
  Page* owner=matches(preferred_owner) ? preferred_owner : nullptr;
  if (!owner) for (auto& entry : pages) if (matches(entry.first)) { owner=entry.first; break; }
  if (!owner) return nullptr;
  if (!window) {
    Page* member=Allocate(owner->context_key);
    member->group=owner; member->awaiting_context=false; member->navigated=true; member->awaiting_window=true;
    return member;
  }
  Page* child=Allocate(owner->context_key);
  child->awaiting_context=false; child->navigated=true; child->pending_popup=true;
  child->view.auxiliary=YES; child->view.browserWindow=window;
  const std::string url=browser->GetMainFrame()->GetURL().ToString();
  if (!owner->popup(owner->callback_context,child,url.c_str())) { Destroy(child); return nullptr; }
  Trace("native auxiliary Chrome window adopted");
  return child;
}

void ReconcileWindows() {
  if (reconciling_windows) return;
  reconciling_windows=true;
  struct ResetReconciliation { ~ResetReconciliation() { reconciling_windows=false; } } reset_reconciliation;
  std::vector<Page*> snapshot;
  for (const auto& entry : pages) if (entry.first->browser) snapshot.push_back(entry.first);
  for (Page* member : snapshot) {
    if (!pages.count(member) || !member->browser) continue;
    Page* old_owner=Group(member);
    NSView* handle=(NSView*)member->browser->GetHost()->GetWindowHandle();
    NSWindow* window=[handle window];
    if (!window || old_owner->creating) continue;
    if (old_owner->closing || old_owner->admission_closed) {
      if (member->awaiting_window || old_owner->view.browserWindow!=window) member->browser->GetHost()->CloseBrowser(true);
      continue;
    }
    if (!old_owner->view.browserWindow && member==old_owner) {
      old_owner->view.browserWindow=window;
      if (!old_owner->view.auxiliary) { window.hasShadow=NO; window.excludedFromWindowsMenu=YES; window.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary; }
    }
    if (old_owner->view.browserWindow==window) {
      if (member->awaiting_window) {
        size_t count=0; for (Page* candidate : Members(old_owner)) if (candidate->browser) ++count;
        if (count>200) {
          Message(old_owner,RADIUS_CEF_NOTICE,"A Chromium pane supports up to 200 tabs.");
          member->browser->GetHost()->CloseBrowser(true); continue;
        }
      }
      member->awaiting_window=false; continue;
    }
    Page* owner=nullptr;
    bool destination_closed=false;
    for (const auto& entry : pages)
      if (Group(entry.first)==entry.first && entry.first->context_key==old_owner->context_key &&
          entry.first->view.browserWindow==window) {
        if (entry.first->closing || entry.first->admission_closed) destination_closed=true;
        else owner=entry.first;
        break;
      }
    if (destination_closed) { member->browser->GetHost()->CloseBrowser(true); continue; }
    if (!owner) {
      if (old_owner->closing || !old_owner->popup) { member->browser->GetHost()->CloseBrowser(true); continue; }
      owner=Allocate(old_owner->context_key);
      owner->awaiting_context=false; owner->pending_popup=true;
      owner->view.auxiliary=YES; owner->view.chromeStyle=YES; owner->view.navigationChrome=YES;
      owner->view.browserWindow=window; owner->management=old_owner->management;
      const std::string url=member->browser->GetMainFrame()->GetURL().ToString();
      if (!old_owner->popup(old_owner->callback_context,owner,url.c_str())) {
        Destroy(owner); member->browser->GetHost()->CloseBrowser(true); continue;
      }
      owner->pending_popup=false;
    }
    size_t member_count=0; for (Page* candidate : Members(owner)) if (candidate->browser) ++member_count;
    if (member_count>=200) {
      Message(old_owner,RADIUS_CEF_NOTICE,"A Chromium pane supports up to 200 tabs. The moved tab could not be retained.");
      member->browser->GetHost()->CloseBrowser(true); continue;
    }
    // The original Page is the stable native pane handle. Extract its initial
    // WebContents before moving it; never move the Swift owner or its anchor.
    if (member==old_owner) {
      Page* extracted=Allocate(member->context_key);
      extracted->group=old_owner; extracted->awaiting_context=false;
      extracted->browser=member->browser; extracted->browser_id=member->browser_id; extracted->browser_created=true;
      extracted->client=member->client; extracted->client->AttachPage(extracted);
      extracted->observer=member->observer; extracted->navigated=member->navigated;
      extracted->title=member->title; extracted->navigation_failed=member->navigation_failed;
      extracted->failure_message=member->failure_message; extracted->failed_url=member->failed_url;
      browser_pages[extracted->browser_id]=extracted;
      member->browser=nullptr; member->browser_id=0; member->observer=nullptr;
      member->client=new Client(member); member->active=extracted;
      member=extracted;
    }
    member->group=owner; member->awaiting_window=false;
    if (old_owner->active==member) old_owner->active=nullptr;
    RefreshActive(owner); if (auto active=Active(owner)) State(active);
    RefreshActive(old_owner); if (auto active=Active(old_owner)) State(active);
    FinishEmptyGroup(old_owner);
  }
}

void CreateReadyPage(Page* page) {
  page->awaiting_context = false;
  page->creating=true;
  CefBrowserSettings settings;
  CefWindowInfo window;
  window.runtime_style=CEF_RUNTIME_STYLE_CHROME;
  window.bounds=CefRect(0,0,800,600);
  // No native parent and no BrowserView: the supported factory creates a
  // normal Chrome browser, with its real tab strip and extension toolbar.
  auto browser=CefBrowserHost::CreateBrowserSync(window,page->client,"about:blank",settings,nullptr,
      contexts.at(page->context_key).value);
  page->creating=false;
  if (browser) {
    NSView* handle=(NSView*)browser->GetHost()->GetWindowHandle();
    page->view.browserWindow=[handle window];
    page->view.browserWindow.hasShadow=NO;
    page->view.browserWindow.excludedFromWindowsMenu=YES;
    page->view.browserWindow.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary;
    [page->view synchronizeBrowserWindow];
  }
  if (!browser) {
    last_error="Chromium could not create a normal browser window. Reopen this pane to retry.";
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
  if (!initialized || stopped || final_quit_frozen) return nullptr;
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
    if (!page->browser) { Destroy(page); return nullptr; }
  }
  return page;
}
void* NativeView(void* opaque) { return static_cast<Page*>(opaque)->view; }
void Callbacks(void* opaque,void* context,radius_cef_event_callback event,radius_cef_popup_callback popup) {
  auto page=static_cast<Page*>(opaque); page->callback_context=context; page->event=event; page->popup=popup;
}
int NativeTabCommand(void* opaque,int command) {
  auto owner=static_cast<Page*>(opaque);
  if (final_quit_frozen || !pages.count(owner) || owner->closing || owner->admission_closed || owner->restoring) return 0;
  ReconcileWindows();
  if (!pages.count(owner) || !RefreshActive(owner)) return 0;
  auto page=Active(owner);
  if (!page || !page->browser) return 0;
  const char* name=nullptr;
  switch (command) {
    case RADIUS_CEF_NEW_TAB: name="IDC_NEW_TAB"; break;
    case RADIUS_CEF_CLOSE_TAB: name="IDC_CLOSE_TAB"; break;
    case RADIUS_CEF_REOPEN_TAB: name="IDC_RESTORE_TAB"; break;
    case RADIUS_CEF_PREVIOUS_TAB: name="IDC_SELECT_PREVIOUS_TAB"; break;
    case RADIUS_CEF_NEXT_TAB: name="IDC_SELECT_NEXT_TAB"; break;
    default: return 0;
  }
  const int id=cef_id_for_command_id_name(name);
  auto host=page->browser->GetHost();
  if (!host->CanExecuteChromeCommand(id)) return 0;
  host->ExecuteChromeCommand(id,CEF_WOD_CURRENT_TAB);
  return 1;
}
void Command(void* opaque,int command,const char* text,double value) {
  auto owner=static_cast<Page*>(opaque); if (!pages.count(owner) || owner->closing) return;
  if (command==RADIUS_CEF_DOWNLOAD_PATH || command==RADIUS_CEF_DOWNLOAD_CANCEL) {
    for (auto& entry : pages) if (entry.first->client->HasDownload(static_cast<int>(value),owner)) {
      if (command==RADIUS_CEF_DOWNLOAD_PATH) entry.first->client->DownloadPath(static_cast<int>(value),text);
      else entry.first->client->CancelDownload(static_cast<int>(value));
      return;
    }
    return;
  }
  if (command==RADIUS_CEF_STOP_ADMISSION) {
    owner->admission_closed=true;
    std::vector<CefRefPtr<Client>> clients; for (const auto& entry : pages) clients.push_back(entry.first->client);
    for (const auto& client : clients) client->CancelNativeDownloads(owner);
    return;
  }
  if (final_quit_frozen && command!=RADIUS_CEF_SYNC_ACTIVE) return;
  if (command==RADIUS_CEF_POPUPS) { owner->popups=value!=0; return; }
  if (command==RADIUS_CEF_RESTORE_TABS) {
    auto parsed=CefParseJSON(text ? text : "",JSON_PARSER_RFC);
    auto list=parsed ? parsed->GetList() : nullptr;
    if (!list || !list->GetSize() || list->GetSize()>200 || owner->restoring) return;
    owner->restore_urls.clear();
    for (size_t i=0;i<list->GetSize();++i) {
      std::string url=list->GetString(i).ToString();
      NSString* raw=[NSString stringWithUTF8String:url.c_str()];
      NSString* scheme=[[[NSURLComponents componentsWithString:raw] scheme] lowercaseString];
      if (url.size()>8192 || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || !Allowed(url))
        url="chrome://newtab/";
      owner->restore_urls.push_back(url);
    }
    owner->restoring=true; owner->restore_failed=false;
    owner->restore_deadline=CFAbsoluteTimeGetCurrent()+30;
    return;
  }
  ReconcileWindows(); if (!pages.count(owner)) return;
  const bool active_known=RefreshActive(owner);
  auto page=Active(owner);
  if (page && !active_known) {
    if (command!=RADIUS_CEF_SYNC_ACTIVE) Message(owner,RADIUS_CEF_NOTICE,"The active Chromium tab is not ready. Try again in a moment.");
    return;
  }
  if (command==RADIUS_CEF_EXTENSIONS || command==RADIUS_CEF_HOME || command==RADIUS_CEF_LOAD) {
    std::string target;
    if (command==RADIUS_CEF_EXTENSIONS) {
      if (owner->context_key.rfind("private:",0)==0) {
        Message(owner,RADIUS_CEF_NOTICE,"Install and manage extensions in a regular profile window."); return;
      }
      owner->management=true; target="chrome://extensions/";
    } else if (command==RADIUS_CEF_HOME) {
      target="chrome://newtab/";
    } else {
      target=text ? text : "";
      if (!Allowed(target)) { Message(owner,RADIUS_CEF_ERROR,"Only HTTP and HTTPS addresses are supported."); return; }
    }
    if (!page) { owner->navigated=true; owner->pending_url=target; return; }
    page->navigated=true; page->pending_url=target;
    page->failure_message.clear(); page->failed_url.clear(); page->navigation_failed=false;
    page->browser->GetMainFrame()->LoadURL(target);
    return;
  }
  if (!page || !page->browser) return;
  auto browser=page->browser; auto host=browser->GetHost();
  switch (command) {
    case RADIUS_CEF_SYNC_ACTIVE: break;
    case RADIUS_CEF_FOCUS_LOCATION:
      [owner->view.browserWindow makeKeyAndOrderFront:nil];
      ++owner->focus_location_requests;
      host->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_FOCUS_LOCATION"),CEF_WOD_CURRENT_TAB);
      break;
    case RADIUS_CEF_RELOAD: browser->Reload(); break;
    case RADIUS_CEF_STOP: browser->StopLoad(); break;
    case RADIUS_CEF_BACK: browser->GoBack(); break;
    case RADIUS_CEF_FORWARD: browser->GoForward(); break;
    case RADIUS_CEF_FOCUS:
      [owner->view.browserWindow makeKeyAndOrderFront:nil];
      host->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_FOCUS_WEB_CONTENTS_PANE"),CEF_WOD_CURRENT_TAB);
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
  int elements=0; bool pressed=false;
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
    if (fixture && cancel && accept) { pressed=[accept accessibilityPerformPress]; if (pressed) break; }
  }
  details->SetList("windows",windows); details->SetList("buttons",buttons);
  return pressed;
}
void DevTools(void* opaque,int id,const char* method,const char* parameters) {
  auto owner=static_cast<Page*>(opaque);
  if (!pages.count(owner) || owner->closing) return;
  ReconcileWindows(); if (!pages.count(owner)) return;
  const bool active_known=RefreshActive(owner);
  auto page=active_known ? Active(owner) : nullptr;
  if (diagnostics && std::string(method)=="Radius.chromeHostState") {
    auto result=CefDictionaryValue::Create();
    NSWindow* window=owner->view.browserWindow;
    const bool toolbar=page && page->browser && page->browser->GetHost()->CanExecuteChromeCommand(
        cef_id_for_command_id_name("IDC_FOCUS_LOCATION"));
    result->SetBool("normalWindow",true);
    result->SetBool("toolbarPresent",toolbar);
    result->SetBool("toolbarVisible",toolbar && window.visible);
    result->SetBool("toolbarDrawn",toolbar && window.visible);
    result->SetBool("windowVisible",window.visible);
    result->SetBool("windowActive",window.keyWindow);
    result->SetInt("activeBrowser",page ? page->browser_id : 0);
    result->SetInt("focusLocationRequests",owner->focus_location_requests);
    auto members=CefListValue::Create();
    for (Page* member : Members(owner)) if (member->browser) {
      auto item=CefDictionaryValue::Create(); item->SetInt("id",member->browser_id);
      item->SetString("url",member->browser->GetMainFrame()->GetURL());
      item->SetBool("active",member==page);
      members->SetDictionary(members->GetSize(),item);
    }
    result->SetList("browsers",members);
    auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",true);
    response->SetDictionary("result",result); EmitOwned(owner,RADIUS_CEF_RESULT,response); return;
  }
  if (diagnostics && std::string(method)=="Radius.acceptFixtureExtension") {
    auto result=CefDictionaryValue::Create(); result->SetBool("pressed",AcceptFixtureExtension(owner,result));
    auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",true);
    response->SetDictionary("result",result); EmitOwned(owner,RADIUS_CEF_RESULT,response); return;
  }
  auto value=CefParseJSON(parameters,JSON_PARSER_RFC);
  if (page && page->browser) {
    page->client->ExecuteRequest(owner,id,method,value ? value->GetDictionary() : nullptr);
    return;
  }
  auto response=CefDictionaryValue::Create(); response->SetInt("id",id); response->SetBool("success",false);
  EmitOwned(owner,RADIUS_CEF_RESULT,response);
}
void Close(void* opaque) {
  auto owner=static_cast<Page*>(opaque); if (!pages.count(owner)) return;
  owner->event=nullptr; owner->popup=nullptr; owner->callback_context=nullptr; owner->closing=true;
  owner->awaiting_context=false;
  owner->restore_urls.clear(); owner->restore_selection=nullptr; owner->restoring=false;
  std::vector<CefRefPtr<Client>> clients; for (const auto& entry : pages) clients.push_back(entry.first->client);
  for (const auto& client : clients) client->CancelNativeDownloads(owner);
  if (!pages.count(owner)) return;
  auto members=Members(owner);
  bool waiting=false;
  for (Page* member : members) {
    if (!pages.count(member)) continue;
    if (member->browser) { waiting=true; member->browser->GetHost()->CloseBrowser(true); }
    else if (member->pending_popup) waiting=true;
  }
  if (!waiting && pages.count(owner)) FinishEmptyGroup(owner);
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
void SetFinalQuitFrozen(int frozen) { final_quit_frozen=frozen!=0; }
const radius_cef_api api={4,Initialize,Error,Create,NativeView,Callbacks,Command,DevTools,Close,Live,Shutdown,ReleasePrivateContexts,NativeTabCommand,SetFinalQuitFrozen};
}
extern "C" __attribute__((visibility("default"))) const radius_cef_api* radius_cef_get_api() { return &api; }
