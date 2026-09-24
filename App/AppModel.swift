import Foundation
import UIKit
import SwiftUI
import Photos
import CoreGraphics
import CopilotKit
import JudgeClient

/// Everything the views talk to. Keeps the platform glue (Photos, pasteboard) apart from the
/// platform-neutral `CopilotKit` so the interesting logic stays testable.
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case reading
        case judging
        case done
        case failed(String)
    }

    @Published var settings: CopilotSettings
    @Published var phase: Phase = .idle
    @Published var outcome: CopilotService.Outcome?
    @Published var lastImage: UIImage?
    @Published var note: String?

    let knowledge: KnowledgeStore
    private var service: CopilotService

    init(settings: CopilotSettings = .load(),
         knowledge: KnowledgeStore = KnowledgeStore()) {
        self.settings = settings
        self.knowledge = knowledge
        self.service = CopilotService(settings: settings, knowledge: knowledge)
    }

    private func rebuildService() {
        service = CopilotService(settings: settings, knowledge: knowledge)
    }

    func saveSettings() {
        settings.save()
        rebuildService()
        note = "已保存"
    }

    // MARK: analysis

    /// Runs the on-device self-test: a bundled corpus screenshot plus the output recorded for it,
    /// so an install can be verified without sending any screenshot of a real conversation.
    func selfTest(screen: String) async -> SelfTestReport {
        await SelfTest.run(settings: settings, screen: screen, transport: transport)
    }

    func analyze(image: UIImage, contactName: String? = nil) async {
        guard let cgImage = image.cgImage else {
            phase = .failed("这张图读不出来")
            return
        }
        lastImage = image
        phase = .reading
        do {
            phase = .judging
            let result = try await service.analyze(image: cgImage, contactName: contactName)
            outcome = result
            phase = .done
        } catch {
            phase = .failed(AppModel.describe(error))
        }
    }

    func analyze(text: String, contactName: String? = nil) async {
        phase = .judging
        do {
            outcome = try await service.analyze(transcript: text, contactName: contactName)
            phase = .done
        } catch {
            phase = .failed(AppModel.describe(error))
        }
    }

    /// The one-gesture path: analyse the newest screenshot in the library.
    func analyzeNewestScreenshot() async {
        phase = .reading
        guard await ScreenshotIntake.ensureAccess() else {
            phase = .failed("没有照片权限，无法读取截图")
            return
        }
        guard let image = await ScreenshotIntake.newestScreenshot() else {
            phase = .failed("相册里没有找到截图")
            return
        }
        await analyze(image: image)
    }

    // MARK: handoff to the keyboard

    func copyForKeyboard(_ text: String) {
        UIPasteboard.general.string = ClipboardHandoff.encode(text)
        note = "已放到剪贴板，键盘里点「插入剪贴板」即可"
    }

    func saveContactFromConversation() {
        guard let snapshot = outcome?.snapshot else { return }
        knowledge.saveContact(fromSender: snapshot.contactName ?? "", transcript: snapshot.transcript)
        note = "已存为联系人"
    }

    func probe(_ kind: RouteKind) async -> ProbeResult {
        await service.probe(kind)
    }

    /// Route labels for the settings screen.
    static func label(_ kind: RouteKind) -> String {
        switch kind {
        case .judgment: return "判断接口"
        case .reply: return "回复接口"
        case .vision: return "视觉接口"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let http = error as? HTTPError { return http.description }
        if let route = error as? RouteConfigurationError { return route.description }
        return error.localizedDescription
    }
}