import SwiftUI

struct IslandView: View {
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.8)

    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.size
        let radius: CGFloat = model.isExpanded ? 26 : 8
        ZStack(alignment: .top) {
            if model.isExpanded {
                expanded
                    // Фиксированный размер: при изменении формы контент не перестраивается, а только масштабируется.
                    .frame(width: model.expandedSize.width, height: model.expandedSize.height)
                    // Появляется из камеры и уезжает в неё — быстрее формы, чтобы не отставать.
                    .transition(.scale(scale: 0.3, anchor: .top).combined(with: .opacity)
                        .animation(.easeIn(duration: 0.15)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.black)
        // Контент не вылезает за остров, пока тот растёт.
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
        // Без выреза в свёрнутом виде остров полностью невидим.
        .opacity(!model.isExpanded && !model.hasNotch ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.spring, value: model.isExpanded)
        .environment(\.colorScheme, .dark)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                menuButton
                Spacer(minLength: model.notch.width + 20) // центр занят камерой
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(PressStyle())
                .help("Закрыть BigIsland")
            }
            .foregroundStyle(.white)
            .frame(height: model.notch.height)
            .padding(.horizontal, 16)

            Group {
                if model.menuOpen { featureList } else { model.selectedFeature?.makeView() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 6)
            .frame(maxHeight: .infinity)
        }
    }

    /// Одна кнопка вместо вкладок: текущая фича, по нажатию — список всех.
    private var menuButton: some View {
        let feature = model.selectedFeature
        return Button { withAnimation(.easeOut(duration: 0.15)) { model.menuOpen.toggle() } } label: {
            HStack(spacing: 5) {
                Label(feature?.title ?? "", systemImage: feature?.icon ?? "square.grid.2x2")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(model.menuOpen ? 180 : 0))
            }
            .font(.system(size: 12, weight: .semibold))
            .tracking(-0.12)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.tile))
        }
        .buttonStyle(PressStyle())
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.features, id: \.id) { feature in
                let selected = feature.id == model.selectedFeature?.id
                Button {
                    withAnimation(Self.spring) {
                        model.selectedFeatureID = feature.id
                        model.menuOpen = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: feature.icon).frame(width: 16)
                        Text(feature.title)
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .tracking(-0.12)
                    .foregroundStyle(selected ? .white : Theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(width: 200)
                    .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected ? Theme.tile : .clear))
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }
}
