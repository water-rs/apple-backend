import CWaterUI
import Testing

@testable import WaterUI

@MainActor
struct WatcherMetadataTests {
  @Test func nilMetadataReportsNoAnimation() {
    let metadata = WuiWatcherMetadata(nil)
    #expect(metadata.getAnimation().tag == WuiAnimation_None)
    #expect(metadata.animation == nil)
  }
}
