import LumenKit

// Thin executable shell: all application code lives in the LumenKit library so
// the LumenTests harness can import and exercise it directly.
@main
struct LumenMain {
    static func main() {
        MainActor.assumeIsolated {
            LumenEntry.run()
        }
    }
}
