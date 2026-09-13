import Testing

@testable import WaterUI

@MainActor
struct WrapperCallTests {
  @Test func callWrapperInvokesTheWrappedClosure() {
    var received: Int32?
    var metadataWasNil = false
    let data = wrap { (value: Int32, metadata: WuiWatcherMetadata) in
      received = value
      metadataWasNil = metadata.inner == nil
    }
    callWrapper(data, 41, nil)
    #expect(received == 41)
    #expect(metadataWasNil)
    dropWrapper(data, Int32.self)
  }
}
