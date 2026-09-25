import Foundation
import AgentCore

// Placeholder for the XPC privilege split (step 6 in README.md).
//
// This target exists now so the package resolves and so the boundary is
// visible in the project structure from day one. Until it is implemented,
// VirtualizationSandbox runs in the app process, which means the app needs the
// virtualization entitlement.
//
// That is an acceptable state for the spike and NOT an acceptable end state:
// the component handling untrusted web content and model output should not be
// able to drive a hypervisor. See ../../docs/SECURITY.md.

print("SandboxHelper is not implemented yet. See macos/README.md step 6.")
