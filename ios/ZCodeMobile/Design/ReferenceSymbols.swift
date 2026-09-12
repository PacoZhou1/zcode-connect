import SwiftUI

struct FolderGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1.1, y: 4.7))
        path.addLine(to: CGPoint(x: 1.1, y: 2.6))
        path.addQuadCurve(to: CGPoint(x: 2.5, y: 1.2), control: CGPoint(x: 1.1, y: 1.2))
        path.addLine(to: CGPoint(x: 4.7, y: 1.2))
        path.addLine(to: CGPoint(x: 6.5, y: 3.1))
        path.addLine(to: CGPoint(x: 11.5, y: 3.1))
        path.addQuadCurve(to: CGPoint(x: 12.9, y: 4.5), control: CGPoint(x: 12.9, y: 3.1))
        path.addLine(to: CGPoint(x: 12.9, y: 11.1))
        path.addQuadCurve(to: CGPoint(x: 11.5, y: 12.5), control: CGPoint(x: 12.9, y: 12.5))
        path.addLine(to: CGPoint(x: 2.5, y: 12.5))
        path.addQuadCurve(to: CGPoint(x: 1.1, y: 11.1), control: CGPoint(x: 1.1, y: 12.5))
        path.addLine(to: CGPoint(x: 1.1, y: 4.7))
        path.addLine(to: CGPoint(x: 12.9, y: 4.7))
        return path.applying(CGAffineTransform(scaleX: rect.width / 14, y: rect.height / 14))
    }
}

struct ChatGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3.9, y: 12.1))
        path.addCurve(to: CGPoint(x: 1.2, y: 7), control1: CGPoint(x: 2.2, y: 11.1), control2: CGPoint(x: 1.2, y: 9.2))
        path.addCurve(to: CGPoint(x: 7, y: 1.2), control1: CGPoint(x: 1.2, y: 3.8), control2: CGPoint(x: 3.8, y: 1.2))
        path.addCurve(to: CGPoint(x: 12.8, y: 7), control1: CGPoint(x: 10.2, y: 1.2), control2: CGPoint(x: 12.8, y: 3.8))
        path.addCurve(to: CGPoint(x: 7, y: 12.8), control1: CGPoint(x: 12.8, y: 10.2), control2: CGPoint(x: 10.2, y: 12.8))
        path.addQuadCurve(to: CGPoint(x: 4.8, y: 12.4), control: CGPoint(x: 5.8, y: 12.8))
        path.addLine(to: CGPoint(x: 1.3, y: 12.9))
        path.addLine(to: CGPoint(x: 2, y: 10))
        return path.applying(CGAffineTransform(scaleX: rect.width / 14, y: rect.height / 14))
    }
}

struct MenuLinesGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 7))
        path.addLine(to: CGPoint(x: 21, y: 7))
        path.move(to: CGPoint(x: 1, y: 17))
        path.addLine(to: CGPoint(x: 13, y: 17))
        return path.applying(CGAffineTransform(scaleX: rect.width / 22, y: rect.height / 24))
    }
}

struct RobotGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 3.2, y: 6, width: 13.6, height: 11), cornerSize: CGSize(width: 3, height: 3))
        path.move(to: CGPoint(x: 10, y: 2.2))
        path.addLine(to: CGPoint(x: 10, y: 6))
        path.move(to: CGPoint(x: 1, y: 9.5))
        path.addLine(to: CGPoint(x: 1, y: 13))
        path.move(to: CGPoint(x: 19, y: 9.5))
        path.addLine(to: CGPoint(x: 19, y: 13))
        path.move(to: CGPoint(x: 7, y: 10))
        path.addLine(to: CGPoint(x: 7, y: 12))
        path.move(to: CGPoint(x: 13, y: 10))
        path.addLine(to: CGPoint(x: 13, y: 12))
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20))
    }
}

struct BranchShareGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 1, y: 8)); p.addLine(to: CGPoint(x: 6, y: 8))
        p.addLine(to: CGPoint(x: 14, y: 1)); p.move(to: CGPoint(x: 9, y: 1))
        p.addLine(to: CGPoint(x: 14, y: 1)); p.addLine(to: CGPoint(x: 14, y: 6))
        p.move(to: CGPoint(x: 8, y: 10)); p.addLine(to: CGPoint(x: 14, y: 15))
        p.move(to: CGPoint(x: 10, y: 15)); p.addLine(to: CGPoint(x: 14, y: 15))
        p.addLine(to: CGPoint(x: 14, y: 11))
        return p.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16))
    }
}

struct TargetArrowGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: 11, y: 12), radius: 9, startAngle: .degrees(-75), endAngle: .degrees(-15), clockwise: true)
        p.move(to: CGPoint(x: 11.955, y: 6.5836))
        p.addArc(center: CGPoint(x: 11, y: 12), radius: 5.5, startAngle: .degrees(-80), endAngle: .degrees(-10), clockwise: true)
        p.move(to: CGPoint(x: 11, y: 12)); p.addLine(to: CGPoint(x: 20, y: 3))
        p.addLine(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 16, y: 0.8))
        p.move(to: CGPoint(x: 20, y: 3)); p.addLine(to: CGPoint(x: 20, y: 7))
        p.addLine(to: CGPoint(x: 22.2, y: 7))
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct PlanListGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 2, y: 3, width: 5, height: 5))
        p.addEllipse(in: CGRect(x: 2, y: 14, width: 5, height: 5))
        p.move(to: CGPoint(x: 12, y: 5.5)); p.addLine(to: CGPoint(x: 22, y: 5.5))
        p.move(to: CGPoint(x: 12, y: 16.5)); p.addLine(to: CGPoint(x: 22, y: 16.5))
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct DocumentReferenceIcon: View {
    var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 6, topTrailingRadius: 0)
                .fill(Color(red: 0.12, green: 0.43, blue: 0.91))
            VStack(alignment: .leading, spacing: 3) {
                Rectangle().frame(width: 15, height: 1.7)
                Rectangle().frame(width: 15, height: 1.7)
                Rectangle().frame(width: 10, height: 1.7)
            }.foregroundStyle(.white).offset(y: 7)
            Path { p in p.move(to: CGPoint(x: 16, y: 0)); p.addLine(to: CGPoint(x: 28, y: 12)); p.addLine(to: CGPoint(x: 16, y: 12)); p.closeSubpath() }
                .fill(Color(red: 0.55, green: 0.72, blue: 0.98))
        }.frame(width: 28, height: 34)
    }
}

struct VoiceBarsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, height) in [5.0, 16.0, 10.0, 4.0].enumerated() {
            let x = rect.minX + rect.width * (2.5 + Double(index) * 5) / 20
            let half = rect.height * height / 44
            path.move(to: CGPoint(x: x, y: rect.midY - half))
            path.addLine(to: CGPoint(x: x, y: rect.midY + half))
        }
        return path
    }
}

struct ComposeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 10, y: 3))
        path.addLine(to: CGPoint(x: 6, y: 3))
        path.addCurve(to: CGPoint(x: 2.5, y: 6.5), control1: CGPoint(x: 3.6, y: 3), control2: CGPoint(x: 2.5, y: 4.1))
        path.addLine(to: CGPoint(x: 2.5, y: 18))
        path.addCurve(to: CGPoint(x: 6.5, y: 22), control1: CGPoint(x: 2.5, y: 20.7), control2: CGPoint(x: 3.8, y: 22))
        path.addLine(to: CGPoint(x: 18, y: 22))
        path.addCurve(to: CGPoint(x: 22, y: 18), control1: CGPoint(x: 20.7, y: 22), control2: CGPoint(x: 22, y: 20.7))
        path.addLine(to: CGPoint(x: 22, y: 14.5))
        path.move(to: CGPoint(x: 8.7, y: 16.6))
        path.addLine(to: CGPoint(x: 9.5, y: 12.5))
        path.addLine(to: CGPoint(x: 18.4, y: 3.5))
        path.addCurve(to: CGPoint(x: 22, y: 7.1), control1: CGPoint(x: 21.2, y: 0.7), control2: CGPoint(x: 24.8, y: 4.3))
        path.addLine(to: CGPoint(x: 13, y: 15.9))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 25, y: rect.height / 25)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
