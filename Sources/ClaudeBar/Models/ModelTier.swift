import Foundation

/// Plain-language characterization of a model family, so a non-expert understands
/// what each model is for and the trade-off — qualitative, not benchmark numbers.
struct ModelTier {
    let short: String   // one-word tag shown next to the model name
    let blurb: String   // tooltip: what it's good for + the trade-off

    static func of(_ model: String) -> ModelTier? {
        let m = model.lowercased()
        if m.contains("opus") {
            return ModelTier(short: "최고 성능",
                blurb: "가장 똑똑한 모델 — 복잡한 추론·설계·어려운 코딩에 강합니다. 대신 가장 느리고 비쌉니다.")
        }
        if m.contains("sonnet") {
            return ModelTier(short: "균형",
                blurb: "성능과 속도의 균형 — 대부분의 코딩·일상 작업에 적합합니다. 빠르고 비용도 합리적이에요.")
        }
        if m.contains("haiku") {
            return ModelTier(short: "초고속·저렴",
                blurb: "가볍고 매우 빠름 — 간단·반복 작업, 요약·분류에 적합합니다. 비용이 가장 낮아요.")
        }
        if m.contains("fable") {
            return ModelTier(short: "초고속",
                blurb: "빠른 응답에 특화된 경량 모델 — 가벼운 작업에 적합합니다.")
        }
        return nil
    }

    /// One-line note about reasoning effort (not tracked locally, shown as guidance).
    static let effortNote = "같은 모델이라도 추론 강도(effort)를 높이면 더 정확하지만 느리고 토큰을 더 씁니다."
}
