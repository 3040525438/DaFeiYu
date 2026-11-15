import SwiftUI
import DFCore

/// D21：后台任务与运行方式说明。
///
/// 只做说明，不提供"保证准点"之类的开关；
/// 所有文案来自 `BackgroundExecutionPolicy.disclosure`，避免各处漂移。
@MainActor
struct BackgroundSettingsView: View {
    var body: some View {
        List {
            Section {
                Text(BackgroundExecutionPolicy.disclosure.timing)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("时间")
            }

            Section {
                ForEach(BackgroundExecutionPolicy.disclosure.whatRuns, id: \.self) { item in
                    Text(item)
                        .font(.footnote)
                }
            } header: {
                Text("后台会做什么")
            }

            Section {
                Text(BackgroundExecutionPolicy.disclosure.cost)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("成本")
            }

            Section {
                Text(BackgroundExecutionPolicy.disclosure.privacy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("后台与运行方式")
        .navigationBarTitleDisplayMode(.inline)
    }
}
