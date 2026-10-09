// SPDX-License-Identifier: MPL-2.0
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc,char* argv[]) {
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc,argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc,argv),nullptr,nullptr);
}
