import Foundation

/// Plain-language characterization of a model family, so a non-expert understands
/// what each model is for and the trade-off — qualitative, not benchmark numbers.
struct ModelTier {
    let short: String   // one-word tag shown next to the model name
    let useFor: String  // recommended kinds of work (model-routing guidance)
    let blurb: String   // tooltip: what it's good for + the trade-off

    static func of(_ model: String) -> ModelTier? {
        let m = model.lowercased()
        if m.contains("fable") {
            return ModelTier(short: "최고 성능", useFor: "가장 어려운 추론·긴 작업",
                blurb: "가장 성능이 높은 모델 — 어렵고 오래 걸리는 작업에 강합니다. 대신 단가가 가장 높아(Opus 5.5의 약 2배) 한도도 가장 빨리 씁니다.")
        }
        if m.contains("opus") {
            return ModelTier(short: "고성능", useFor: "어려운 코딩·설계·디버깅",
                blurb: "강력한 범용 모델 — 복잡한 코딩·설계에 강합니다. Fable보다 단가가 약 절반이라 대부분의 어려운 작업에 가성비가 좋아요.")
        }
        if m.contains("sonnet") {
            return ModelTier(short: "균형", useFor: "일상 코딩·리팩토링",
                blurb: "성능과 속도의 균형 — 대부분의 코딩·일상 작업에 적합합니다. 빠르고 비용도 합리적이에요.")
        }
        if m.contains("haiku") {
            return ModelTier(short: "초고속·저렴", useFor: "단순 편집·요약·분류",
                blurb: "가볍고 매우 빠름 — 간단·반복 작업, 요약·분류에 적합합니다. 비용이 가장 낮아요.")
        }
        return nil
    }

    /// One-line note about reasoning effort (not tracked locally, shown as guidance).
    static let effortNote = "같은 모델이라도 추론 강도(effort)를 높이면 더 정확하지만 느리고 토큰을 더 씁니다."
}
