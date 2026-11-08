import SwiftUI

/// CarPlay 界面预览：把 CarPlayRootView 放进固定 800×480 画布，手机上就能看布局效果。
/// 注意：这不是真实 CarPlay 运行时（那需要 Apple 审批的 carplay-audio 能力 + 车机/模拟器），
/// 只用于验证 SwiftUI 布局、字号、行高、截断等视觉问题。
struct CarPlayPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fitToWidth = true

    private let canvas = CGSize(width: 800, height: 480)

    var body: some View {
        NavigationView {
            GeometryReader { proxy in
                let scale = fitToWidth ? min(1, (proxy.size.width - 32) / canvas.width) : 1
                ScrollView([.horizontal, .vertical], showsIndicators: !fitToWidth) {
                    VStack(spacing: 14) {
                        CarPlayRootView()
                            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
                            .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
                            .padding(.top, 16)

                        Text("800×480 · 仅模拟 CarPlay 的 SwiftUI 布局，非真实车机运行时")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(white: 0.06))
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("CarPlay 预览")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(fitToWidth ? "1:1" : "适应") { fitToWidth.toggle() }
                }
            }
            .preferredColorScheme(.dark)
        }
        .navigationViewStyle(.stack)
    }
}
