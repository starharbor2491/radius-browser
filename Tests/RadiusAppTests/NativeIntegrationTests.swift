// SPDX-License-Identifier: MPL-2.0
import Testing

// Native fixtures share NSApplication and the process-wide worker registries.
// Serialize the whole group so one fixture cannot cancel another's workers.
@Suite(.serialized)
struct NativeIntegrationTests {}
