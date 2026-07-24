import Testing
@testable import AccioComputerUseKit

@Test("screen recording explanation says screenshots are on demand")
func screenRecordingExplanationIsHonest() {
    let chinese = PrivacyCopy.screenRecordingExplanation(isChinese: true)
    let english = PrivacyCopy.screenRecordingExplanation(isChinese: false)

    #expect(chinese.contains("按需截取"))
    #expect(chinese.contains("不会持续录制视频"))
    #expect(english.contains("only when an agent requests"))
    #expect(english.contains("does not continuously record video"))
}
