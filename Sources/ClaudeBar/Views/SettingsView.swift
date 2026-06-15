import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled

    // Edit budget in millions for a friendlier control.
    private var budgetMillions: Binding<Double> {
        Binding(get: { Double(store.fiveHourTokenBudget) / 1_000_000 },
                set: { store.fiveHourTokenBudget = Int($0 * 1_000_000) })
    }

    var body: some View {
        Form {
            Section("플랜 한도 (라이브)") {
                Toggle("실제 세션·주간 한도 표시", isOn: $store.enableLiveLimits)
                Text("Claude Code 로그인으로 Claude 사용량 엔드포인트에서 실제 세션(5시간)·주간(7일) 사용률을 가져옵니다. 네트워크가 필요하며, 첫 조회 시 키체인 자격증명 접근 권한을 한 번 묻습니다. 요청 제한을 피하려 3분간 캐시합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("일반") {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        // 등록 실패(예: 번들 아닌 실행) 시 토글을 되돌립니다.
                        if !LoginItem.setEnabled(on) { launchAtLogin = LoginItem.isEnabled }
                    }
            }

            Section("메뉴바") {
                Picker("표시", selection: Binding(
                    get: { store.barMetric },
                    set: { store.barMetric = $0 })) {
                    ForEach(BarMetric.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("모델별 소진") {
                Picker("비교 기준", selection: Binding(
                    get: { store.burnBasis },
                    set: { store.burnBasis = $0 })) {
                    ForEach(BurnBasis.allCases) { Text($0.label).tag($0) }
                }
                Text("총 토큰 ≈ 한도 압박(캐시 읽기가 지배적이라 모델이 비슷해 보임). 비용은 모델 간 실제 격차를 드러냄. 신규 토큰은 새 작업량만.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("알림") {
                HStack {
                    Text("경고 임계값")
                    Slider(value: Binding(
                        get: { Double(store.warnThreshold) },
                        set: { store.warnThreshold = Int($0) }), in: 50...100, step: 5)
                    Text("\(store.warnThreshold)%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Toggle("한도가 임계값을 넘으면 알림", isOn: $store.notifyOnWarning)
                    .disabled(!store.enableLiveLimits)
                Text("세션 또는 주간 한도가 이 임계값을 넘으면 메뉴바 아이콘이 주황 ⚠︎로 바뀝니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("새로고침") {
                Picker("주기", selection: $store.refreshInterval) {
                    Text("30초").tag(30.0)
                    Text("1분").tag(60.0)
                    Text("5분").tag(300.0)
                    Text("15분").tag(900.0)
                }
            }

            Section("5시간 윈도우 미터") {
                HStack {
                    Slider(value: budgetMillions, in: 10...500, step: 10)
                    Text("\(Int(budgetMillions.wrappedValue))M")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("미터가 채워지는 기준 소프트 예산. Claude는 정확한 5시간 토큰 상한을 공개하지 않으므로, 본인 플랜 체감에 맞춰 설정하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("비용은 공개 정가 기준 추정치입니다. 모델별 단가는 ~/.claudebar/pricing.json 에서 덮어쓸 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 560)
    }
}
