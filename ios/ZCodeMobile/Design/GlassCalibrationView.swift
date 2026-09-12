#if DEBUG
import SwiftUI

struct GlassCalibrationView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 30) {
                    Text("官方材质基准 · 相同尺寸与背景").font(.headline)
                    ZStack {
                        VStack(spacing: 8) {
                            ForEach(0..<7) { index in
                                HStack {
                                    Text("Example-Mac.local").foregroundStyle(index.isMultiple(of: 2) ? .purple : .primary)
                                    Spacer()
                                    Text("正在继续你的工作").foregroundStyle(.secondary)
                                }
                            }
                        }.font(.system(size: 17))
                        VStack(spacing: 24) {
                            Text("glassEffect(.clear)").frame(maxWidth: .infinity).frame(height: 48)
                                .glassEffect(.clear, in: Capsule())
                            Text("glassEffect(.regular)").frame(maxWidth: .infinity).frame(height: 48)
                                .glassEffect(.regular, in: Capsule())
                        }
                    }.frame(height: 210)
                    HStack(spacing: 30) {
                        Button {} label: { Image(systemName: "plus").frame(width: 34, height: 34) }
                            .buttonStyle(.glass(.clear))
                        Button {} label: { Image(systemName: "plus").frame(width: 34, height: 34) }
                            .buttonStyle(.glass)
                    }.font(.system(size: 22)).buttonBorderShape(.circle)
                    Text("文件夹图标与项目文字").font(.headline)
                    ForEach([12.0, 13, 14, 15, 16], id: \.self) { size in
                        HStack(spacing: 6) {
                            Text("\(Int(size)) pt").frame(width: 58, alignment: .leading)
                            Image(systemName: "folder").font(.system(size: size))
                                .measureLayout("folder.\(Int(size))")
                            Text("claude code").font(.system(size: 13))
                            Spacer()
                        }.foregroundStyle(ZTheme.listSecondary)
                    }
                }.padding(24)
            }.navigationTitle("材质与尺寸校准").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "chevron.left") } }
                    ToolbarItem(placement: .topBarTrailing) { Button {} label: { Image(systemName: "ellipsis") } }
                }
        }.tint(.primary)
    }
}
#endif
