import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var dropTarget: PanelSection?

    var body: some View {
        Form {
            Section("플랜 한도 (라이브)") {
                Toggle("실제 세션·주간 한도 표시", isOn: $store.enableLiveLimits)
                Text("Claude Code 로그인으로 Claude 사용량 엔드포인트에서 실제 세션(5시간)·주간(7일) 사용률을 가져옵니다. 네트워크가 필요하며, 첫 조회 시 키체인 자격증명 접근 권한을 한 번 묻습니다(‘항상 허용’ 권장). 이후 토큰이 만료되면 키체인을 다시 묻지 않고 자동 갱신합니다. 요청 제한을 피하려 3분간 캐시합니다.")
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
                HStack {
                    Text("막힘 임박 경고")
                    Slider(value: Binding(
                        get: { Double(store.blockWarnLeadMinutes) },
                        set: { store.blockWarnLeadMinutes = Int($0) }), in: 5...60, step: 5)
                    Text("\(store.blockWarnLeadMinutes)분 전")
                        .monospacedDigit().frame(width: 56, alignment: .trailing)
                }
                .disabled(!store.enableLiveLimits)
                Text("지금 속도면 한도에 막힐 시점이 이 시간 안으로 들어오면 ‘곧 막힘 · ~N분 후’ 알림을 한 번 보냅니다. 메뉴바 라벨도 ‘막힘 50m’처럼 남은 시간으로 바뀝니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("주간 사용 요약 알림", isOn: $store.weeklySummaryEnabled)
                Text("주간 한도가 실제로 리셋되는 시점에 맞춰(라이브 한도가 꺼져 있으면 대략 7일마다) 지난 7일 비용·Opus 비중·재읽기 비율·가장 많이 쓴 프로젝트와 코칭을 한 번에 요약해 보냅니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("한도 많이 남길 때 알림 (더 쓰라고)", isOn: $store.notifyUnderpace)
                    .disabled(!store.enableLiveLimits)
                Text("지금 페이스면 리셋 때 한도가 크게 남을 것 같을 때 한 번 알려줍니다. 자리를 비우면(사용 없음) 울리지 않아요. 기본은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("지금 쓰는 대화가 무거워지면 알림", isOn: $store.notifyCompactSuggestion)
                    .disabled(!store.enableLiveLimits)
                Text("컨텍스트가 크고 재읽기 비중이 높은 대화로 감지되면 그 세션 하나에 대해 한 번 알려줍니다(/compact 제안). 켜두면 새로고침 주기마다 대화 로그를 다시 확인해요(팝오버를 안 열어도 됨) — 그만큼 새로고침 비용이 살짝 늘어요. 기본은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("가벼운 대화인데 Opus면 모델 전환 제안", isOn: $store.notifyModelDownshift)
                    .disabled(!store.enableLiveLimits)
                Text("5시간 창의 주력 모델이 Opus인데 최근 턴들의 출력이 가벼워 보이면, Sonnet으로 바꿔도 될 것 같다고 한 번 알려줍니다(‘모델·effort 회고’ 카드와 같은 판단). 한도 소모량은 그대로고 비용만 바뀝니다 — 모델 선택은 비용을 줄이는 수단이지 한도를 늘리는 수단은 아니에요. 기본은 꺼져 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("한도 위험 알림만 소리가 나요. 코칭성 알림(페이스·/compact·모델 제안)은 소리 없는 배너로, 주간 리캡은 알림 센터에만 조용히 쌓여요. 한도 관련 알림은 배너에서 바로 '2시간 조용히'를, '한도 풀렸어요' 알림은 '지금 이어가기'를 눌러 팝오버를 안 열어도 대응할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("조용한 시간", isOn: $store.quietHoursEnabled)
                if store.quietHoursEnabled {
                    HStack {
                        Text("시작")
                        Picker("", selection: $store.quietHoursStart) {
                            ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        Text("~ 종료")
                        Picker("", selection: $store.quietHoursEnd) {
                            ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                }
                Text("이 시간대엔 알림을 보내지 않아요. 메뉴바 아이콘 색상·팝오버는 그대로 실제 상태를 보여줘요 — 숨기는 게 아니라 방해만 안 하는 거예요.")
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

            Section("진단 (플랜 한도)") {
                if store.enableLiveLimits {
                    diagnosticsRow("마지막 시도",
                        store.lastRefreshAttemptAt.map { Fmt.age($0) } ?? "아직 없음")
                    diagnosticsRow("마지막 성공",
                        (store.limits?.hasData == true) ? Fmt.age(store.limits!.fetchedAt) : "없음")
                    if store.isRefreshing {
                        diagnosticsNote("지금 새로고침 진행 중…", icon: "arrow.triangle.2.circlepath", color: .blue)
                    }
                    if store.lastRefreshTimedOut {
                        diagnosticsNote("마지막 시도가 20초 안에 응답이 없어 건너뜀 — 키체인 응답 대기 등으로 멈췄을 수 있어요. 다음 시도 때 정상화됩니다.",
                                       icon: "hourglass", color: .orange)
                    }
                    if store.liveLimitsBackoff.isBackingOff, let retry = store.liveLimitsBackoff.retryAt {
                        diagnosticsNote("반복 실패로 재시도를 미루는 중 — \(Fmt.countdown(to: retry)) 후 다시 시도해요.",
                                       icon: "clock.arrow.circlepath", color: .orange)
                    }
                    if let err = store.limits?.error {
                        diagnosticsNote(err, icon: "exclamationmark.triangle", color: .red)
                    } else if store.limits?.stale != true, store.limits?.hasData == true {
                        diagnosticsNote("정상", icon: "checkmark.circle", color: .green)
                    }
                    Button("자격증명 캐시 초기화 후 재시도") { store.resetCredentialsAndRetry() }
                        .controlSize(.small)
                    Text("멈춘 것처럼 계속 안 풀리면 눌러보세요 — 캐시된 토큰을 지우고 새로 가져옵니다(키체인 확인 창이 다시 뜰 수 있어요). 문제가 반복되면 이 화면을 캡처해서 알려주세요.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("라이브 한도가 꺼져 있어요 — 진단할 대상이 없습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("비용은 공개 정가 기준 추정치입니다. 모델별 단가는 ~/.claudebar/pricing.json 에서 덮어쓸 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("정보") {
                HStack {
                    Text("CBar")
                    Spacer()
                    Text("버전 \(Self.appVersion)").foregroundStyle(.secondary)
                }
                Text("비공식 도구 · Anthropic과 무관하며 승인받지 않았습니다. 실제 한도는 비공개 엔드포인트에서 가져오므로 예고 없이 중단될 수 있어요. 자기 책임 하에 사용하세요. “Claude”는 Anthropic의 상표입니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("세션·주간 한도 %는 계정 전체 기준(서버 조회)이라 정확하지만, 컨텍스트 크기·모델별 소진·프로젝트별 통계는 이 Mac의 Claude Code 로그만 봅니다 — 다른 기기에서도 쓰신다면 그 사용량은 빠져 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
        .tint(Color.brand)
        // Custom-drawn switch — see BrandToggleStyle's doc comment for why the
        // native NSSwitch-backed style doesn't work correctly in this
        // never-key-window panel.
        .toggleStyle(BrandToggleStyle())
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    @ViewBuilder private func diagnosticsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func diagnosticsNote(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(color)
    }
}
