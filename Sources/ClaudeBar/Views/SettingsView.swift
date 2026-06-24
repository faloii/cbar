import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var dropTarget: PanelSection?

    var body: some View {
        Form {
            Section("플랜 한도 (라이브)") {
                Toggle("실제 세션·주간 한도 표시", isOn: $store.enableLiveLimits)
                Text("Claude Code 로그인으로 Claude 사용량 엔드포인트에서 실제 세션(5시간)·주간(7일) 사용률을 가져옵니다. 네트워크가 필요하며, 첫 조회 시 키체인 자격증명 접근 권한을 한 번 묻습니다. 요청 제한을 피하려 3분간 캐시합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("일반") {
                Picker("테마", selection: Binding(
                    get: { store.appearance },
                    set: { store.appearance = $0 })) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
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

            Section("섹션 (표시 · 순서)") {
                ForEach(store.orderedSections) { section in
                    let sections = store.orderedSections
                    let index = sections.firstIndex(of: section) ?? 0
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary).font(.caption)
                            .accessibilityHidden(true)
                        Toggle(section.label, isOn: Binding(
                            get: { store.isVisible(section) },
                            set: { store.setVisible(section, $0) }))
                        Spacer()
                        Button { store.moveSection(section, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(index == 0)
                        Button { store.moveSection(section, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(index == sections.count - 1)
                    }
                    .contentShape(Rectangle())
                    // Drop indicator: a line above the row currently targeted.
                    .overlay(alignment: .top) {
                        if dropTarget == section {
                            Rectangle().fill(Color.brand).frame(height: 2)
                        }
                    }
                    .draggable(section.rawValue) {
                        Label(section.label, systemImage: "line.3.horizontal").padding(6)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        dropTarget = nil
                        guard let raw = items.first, let moved = PanelSection(rawValue: raw) else { return false }
                        store.moveSection(moved, before: section)
                        return true
                    } isTargeted: { hovering in
                        dropTarget = hovering ? section : (dropTarget == section ? nil : dropTarget)
                    }
                }
                Text("행을 드래그해 순서 변경(또는 ↑↓) · 토글로 표시/숨김.")
                    .font(.caption).foregroundStyle(.secondary)
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

            Section("습관 목표") {
                HStack {
                    Text("Opus 비중 ≤")
                    Slider(value: Binding(
                        get: { Double(store.opusShareTarget) },
                        set: { store.opusShareTarget = Int($0) }), in: 0...100, step: 5)
                    Text(store.opusShareTarget <= 0 ? "끔" : "\(store.opusShareTarget)%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("이번 주 Opus 비용 비중을 목표와 비교하고, 최근 몇 주 준수율을 보여줍니다. 0이면 끕니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("월 예산") {
                HStack {
                    Slider(value: $store.monthlyBudget, in: 0...1000, step: 10)
                    Text(store.monthlyBudget <= 0 ? "끔" : Fmt.usd(store.monthlyBudget))
                        .monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                Text("이번 달 추정 비용과 월말 예상을 예산 대비로 표시합니다. 0이면 끕니다.")
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
                Toggle("주간 사용 요약 알림", isOn: $store.weeklySummaryEnabled)
                Text("매주 한 번 지난 7일 비용·Opus 비중 요약과 코칭을 알림으로 보냅니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("한도 많이 남길 때 알림 (더 쓰라고)", isOn: $store.notifyUnderpace)
                    .disabled(!store.enableLiveLimits)
                Text("지금 페이스면 리셋 때 한도가 크게 남을 것 같을 때 한 번 알려줍니다. 자리를 비우면(사용 없음) 울리지 않아요. 기본은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("막힘 해제 시 자동 재개") {
                Toggle("한도가 풀리면 이전 대화 자동 이어가기", isOn: $store.autoResumeEnabled)
                    .disabled(!store.enableLiveLimits)
                Text("이것만 켜면 됩니다 — 세션 한도에 막혔다가 풀리는 순간, `claude` 경로와 마지막 작업 폴더를 찾아 ‘이전 대화 이어가기’를 싼 모델로 한 번 자동 실행합니다(버튼 안 눌러도 됨).")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("막혀 있는 동안 잠자기 방지", isOn: $store.keepAwakeWhileBlocked)
                    .disabled(!store.enableLiveLimits)
                Text("한도에 막혀 있는 동안만 시스템 잠자기를 막아 리셋을 놓치지 않게 합니다(풀리면 즉시 해제). 화면 보호기·화면 꺼짐은 그대로 허용. 단, 노트북 뚜껑을 닫으면(배터리) 잠자기는 막지 못하고 배터리 소모가 늘 수 있어 기본은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup("명령 직접 지정 (선택)") {
                    Button("기본 명령 채워서 보기/수정") {
                        store.resumeCommand = ResumeCommand.continueLastPreview()
                    }
                    .disabled(!store.enableLiveLimits)
                    TextField("비우면 자동 ‘이전 대화 이어가기’. 예: cd ~/proj && claude --continue -p \"계속\" --model haiku",
                              text: $store.resumeCommand, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(.caption, design: .monospaced))
                    Text("명령칸을 채우면 그 명령이 대신 실행됩니다(모델·프롬프트·폴더 자유). 비워두면 위 자동 동작을 씁니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("새로고침") {
                Picker("주기", selection: $store.refreshInterval) {
                    Text("30초").tag(30.0)
                    Text("1분").tag(60.0)
                    Text("5분").tag(300.0)
                    Text("15분").tag(900.0)
                }
            }

            Section {
                Text("비용은 공개 정가 기준 추정치입니다. 모델별 단가는 ~/.claudebar/pricing.json 에서 덮어쓸 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("정보") {
                HStack {
                    Text("ClaudeBar")
                    Spacer()
                    Text("버전 \(Self.appVersion)").foregroundStyle(.secondary)
                }
                Text("비공식 도구 · Anthropic과 무관하며 승인받지 않았습니다. 실제 한도는 비공개 엔드포인트에서 가져오므로 예고 없이 중단될 수 있어요. 자기 책임 하에 사용하세요. “Claude”는 Anthropic의 상표입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
