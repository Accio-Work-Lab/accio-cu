import Foundation

public enum PrivacyCopy {
    public static func screenRecordingExplanation(isChinese: Bool) -> String {
        if isChinese {
            return "macOS 将截图权限归类为“屏幕录制”。Accio 仅在 Agent 请求观察界面时按需截取画面，不会持续录制视频。"
        }
        return "macOS classifies screenshot access as Screen Recording. Accio captures images only when an agent requests the current interface; it does not continuously record video."
    }
}
