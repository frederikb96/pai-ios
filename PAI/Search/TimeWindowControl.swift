import PAIKit
import SwiftUI

/// The time picker both lists share: a clock button that opens the presets menu, and through it
/// the slider overlay and the custom range form. The window it edits is whatever the host binds;
/// the host decides what narrowing it means.
///
/// The button is accent coloured while a window is active and carries the window's label for
/// VoiceOver. Hosts with a chip row show ``TimeWindowChip`` beside it.
struct TimeWindowButton: View {
    @Binding var window: TimeWindow?

    @State private var isShowingSlider = false
    @State private var isShowingCustom = false

    var body: some View {
        Menu {
            ForEach(TimeWindowPreset.allCases) { preset in
                Button {
                    window = .preset(preset)
                } label: {
                    if window == .preset(preset) {
                        Label(preset.label, systemImage: "checkmark")
                    } else {
                        Text(preset.label)
                    }
                }
            }
            Divider()
            Button {
                openSlider()
            } label: {
                Label("Slider…", systemImage: "slider.horizontal.3")
            }
            Button {
                isShowingCustom = true
            } label: {
                Label("Custom…", systemImage: "calendar")
            }
            if window != nil {
                Divider()
                Button(role: .destructive) {
                    window = nil
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: window == nil ? "clock" : "clock.fill")
                .font(.system(size: 17))
                .foregroundStyle(window == nil ? PaiPalette.Semantic.textMuted : PaiPalette.primary500)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(window.map { "Time window: \($0.label(now: Date()))" } ?? "Time window")
        .accessibilityIdentifier("time-window-button")
        .fullScreenCover(isPresented: $isShowingSlider) {
            TimeWindowSliderOverlay(window: $window)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $isShowingCustom) {
            TimeWindowCustomForm(window: $window)
        }
    }

    /// Opening the slider with no slider window active selects the whole axis at once, so closing
    /// it untouched means "the last 52 weeks" rather than "nothing chosen".
    private func openSlider() {
        var isSliderWindow = false
        if case .slider = window { isSliderWindow = true }
        if !isSliderWindow { window = .slider(.full) }
        isShowingSlider = true
    }
}

/// The active window as a small clearable chip, for hosts that have a chip row.
struct TimeWindowChip: View {
    @Binding var window: TimeWindow?

    var body: some View {
        if let current = window {
            Button {
                window = nil
            } label: {
                HStack(spacing: 4) {
                    Text(current.label(now: Date()))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(PaiTypography.captionEmphasized.font)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PaiPalette.Semantic.accentBackground, in: Capsule())
                .foregroundStyle(PaiPalette.Semantic.accentText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear time window \(current.label(now: Date()))")
            .accessibilityIdentifier("time-window-chip")
        }
    }
}

// MARK: - Slider overlay

/// Full-screen dimmed backdrop with one large card holding the two-thumb range slider. A tap on
/// the backdrop or on the X closes it and keeps the selection; a drag applies on release, not per
/// step, so the list behind does not refetch while a finger is still moving.
struct TimeWindowSliderOverlay: View {
    @Binding var window: TimeWindow?
    @Environment(\.dismiss) private var dismiss

    /// The selection as the finger has it; `window` only follows on release.
    @State private var draft: SliderSelection
    /// Fixed for the lifetime of the overlay so the axis does not shift under a drag.
    @State private var now = Date()

    init(window: Binding<TimeWindow?>) {
        _window = window
        _draft = State(initialValue: window.wrappedValue?.sliderSelection ?? .full)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)

            card
                .padding(.horizontal, 16)
        }
    }

    private var card: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Time window")
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("time-window-slider-close")
            }

            HStack(spacing: 8) {
                Text(TimeWindowSlider.startLabel(draft, now: now))
                Text("–")
                Text(TimeWindowSlider.endLabel(draft, now: now))
            }
            .font(PaiTypography.monoLabel.font)
            .monospacedDigit()
            .foregroundStyle(PaiPalette.Semantic.textPrimary)
            .accessibilityElement(children: .combine)

            TimeWindowRangeSlider(selection: $draft, now: now) { committed in
                window = .slider(committed)
            }
            .frame(height: 96)
        }
        .padding(20)
        .background(PaiPalette.Semantic.panelBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).strokeBorder(PaiPalette.Semantic.borderDefault, lineWidth: 1)
        )
        .accessibilityIdentifier("time-window-slider")
    }
}

/// The two-thumb slider. The whole strip is the touch target: a drag moves whichever thumb is
/// nearer to where the finger landed, so neither thumb has to be hit exactly.
private struct TimeWindowRangeSlider: View {
    @Binding var selection: SliderSelection
    let now: Date
    let onCommit: (SliderSelection) -> Void

    @State private var movingStart: Bool?

    private let thumbSize: CGFloat = 32
    private let trackHeight: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let usable = max(proxy.size.width - thumbSize, 1)
            ZStack(alignment: .topLeading) {
                track(usable: usable)
                monthLabels(usable: usable)
                thumb.offset(x: x(for: selection.from, usable: usable), y: 4)
                thumb.offset(x: x(for: selection.to, usable: usable), y: 4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drag(value, usable: usable) }
                    .onEnded { _ in
                        movingStart = nil
                        onCommit(selection)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Time range")
        .accessibilityValue(
            TimeWindowSlider.startLabel(selection, now: now) + " to "
                + TimeWindowSlider.endLabel(selection, now: now)
        )
        .accessibilityAdjustableAction { direction in
            // VoiceOver moves the end thumb a week at a time; the start is reached by touch.
            let step = direction == .increment ? 1 : -1
            selection = TimeWindowSlider.movingEnd(of: selection, to: selection.to + step)
            onCommit(selection)
        }
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumbSize, height: thumbSize)
            .overlay(Circle().strokeBorder(PaiPalette.primary500, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private func track(usable: CGFloat) -> some View {
        let startX = x(for: selection.from, usable: usable) + thumbSize / 2
        let endX = x(for: selection.to, usable: usable) + thumbSize / 2
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(PaiPalette.Semantic.raisedSurface)
                .frame(height: trackHeight)
            Capsule()
                .fill(PaiPalette.primary500)
                .frame(width: max(endX - startX, 0), height: trackHeight)
                .offset(x: startX)
        }
        .offset(y: 4 + (thumbSize - trackHeight) / 2)
    }

    private func monthLabels(usable: CGFloat) -> some View {
        let symbols = Calendar.current.shortMonthSymbols
        return ZStack(alignment: .topLeading) {
            ForEach(TimeWindowSlider.monthMarks(now: now)) { mark in
                VStack(spacing: 0) {
                    Text(symbols[(mark.month - 1) % symbols.count])
                    if mark.showsYear {
                        Text(String(mark.year)).fontWeight(.semibold)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(1)
                .fixedSize()
                .offset(x: x(for: mark.stop, usable: usable) + thumbSize / 2 - 8, y: 52)
            }
        }
    }

    private func x(for stop: Int, usable: CGFloat) -> CGFloat {
        usable * CGFloat(stop) / CGFloat(TimeWindowSlider.weeks)
    }

    private func drag(_ value: DragGesture.Value, usable: CGFloat) {
        func stop(at x: CGFloat) -> Int {
            TimeWindowSlider.stop(forFraction: Double((x - thumbSize / 2) / usable))
        }
        if movingStart == nil {
            movingStart = TimeWindowSlider.movesStart(
                touchStop: stop(at: value.startLocation.x), selection: selection)
        }
        let target = stop(at: value.location.x)
        let updated =
            movingStart == true
            ? TimeWindowSlider.movingStart(of: selection, to: target)
            : TimeWindowSlider.movingEnd(of: selection, to: target)
        if updated != selection { selection = updated }
    }
}

// MARK: - Custom range form

/// Two whole days, typed and shown as `YYYY-MM-DD` whatever the device's locale prefers. Both
/// ends are inclusive.
struct TimeWindowCustomForm: View {
    @Binding var window: TimeWindow?
    @Environment(\.dismiss) private var dismiss

    @State private var startText: String
    @State private var endText: String

    init(window: Binding<TimeWindow?>) {
        _window = window
        let today = CalendarDay(Date())
        if case let .custom(from, to)? = window.wrappedValue {
            _startText = State(initialValue: from.isoString)
            _endText = State(initialValue: to.isoString)
        } else {
            let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            _startText = State(initialValue: CalendarDay(monthAgo).isoString)
            _endText = State(initialValue: today.isoString)
        }
    }

    private var start: CalendarDay? { CalendarDay(isoString: startText.trimmingCharacters(in: .whitespaces)) }
    private var end: CalendarDay? { CalendarDay(isoString: endText.trimmingCharacters(in: .whitespaces)) }

    private var problem: String? {
        guard let start, let end else { return "Enter both days as YYYY-MM-DD." }
        return start <= end ? nil : "The start day is after the end day."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    dayField("Start", text: $startText, identifier: "time-window-start")
                    dayField("End", text: $endText, identifier: "time-window-end")
                } footer: {
                    Text(problem ?? "Both days are included in full.")
                        .foregroundStyle(
                            problem == nil ? PaiPalette.Semantic.textMuted : PaiPalette.Semantic.errorText)
                }
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard let start, let end, start <= end else { return }
                        window = .custom(from: start, to: end)
                        dismiss()
                    }
                    .disabled(problem != nil)
                    .accessibilityIdentifier("time-window-apply")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func dayField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(title) {
            TextField("YYYY-MM-DD", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(PaiTypography.monoLabel.font)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Tier divider

/// The one muted row between a tiered list's likely and less likely results.
struct LessLikelyDividerRow: View {
    var body: some View {
        Text(SearchTier.lessLikelyTitle)
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("less-likely-divider")
    }
}
