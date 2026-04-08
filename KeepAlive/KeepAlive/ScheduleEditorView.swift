import SwiftUI

struct ScheduleListView: View {
    @ObservedObject var scheduleManager: ScheduleManager
    @State private var editingSchedule: Schedule?
    @State private var isAddingNew = false

    var body: some View {
        VStack(spacing: 0) {
            if scheduleManager.schedules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Schedules")
                        .font(.headline)
                    Text("Add a schedule to automatically keep\nyour Mac awake at specific times.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(scheduleManager.schedules) { schedule in
                        ScheduleRow(schedule: schedule, isActive: scheduleManager.activeSchedule?.id == schedule.id) {
                            editingSchedule = schedule
                        } onToggle: { enabled in
                            var updated = schedule
                            updated.isEnabled = enabled
                            scheduleManager.updateSchedule(updated)
                            scheduleManager.checkSchedules()
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            scheduleManager.deleteSchedule(id: scheduleManager.schedules[index].id)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    isAddingNew = true
                } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 400, height: 320)
        .sheet(item: $editingSchedule) { schedule in
            ScheduleDetailView(schedule: schedule) { updated in
                scheduleManager.updateSchedule(updated)
                scheduleManager.checkSchedules()
                editingSchedule = nil
            } onDelete: {
                scheduleManager.deleteSchedule(id: schedule.id)
                editingSchedule = nil
            } onCancel: {
                editingSchedule = nil
            }
        }
        .sheet(isPresented: $isAddingNew) {
            ScheduleDetailView(
                schedule: Schedule.defaultSchedule(),
                onSave: { newSchedule in
                    scheduleManager.addSchedule(newSchedule)
                    scheduleManager.checkSchedules()
                    isAddingNew = false
                },
                onDelete: nil,
                onCancel: { isAddingNew = false }
            )
        }
    }
}

struct ScheduleRow: View {
    let schedule: Schedule
    let isActive: Bool
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void

    @State private var enabled: Bool

    init(schedule: Schedule, isActive: Bool, onEdit: @escaping () -> Void, onToggle: @escaping (Bool) -> Void) {
        self.schedule = schedule
        self.isActive = isActive
        self.onEdit = onEdit
        self.onToggle = onToggle
        self._enabled = State(initialValue: schedule.isEnabled)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(schedule.name)
                        .fontWeight(.medium)
                    if isActive {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text("\(schedule.daysDescription) \u{2022} \(schedule.startTime.formatted) – \(schedule.endTime.formatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: enabled) { _, newValue in
                    onToggle(newValue)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

struct ScheduleDetailView: View {
    @State var schedule: Schedule
    let onSave: (Schedule) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var startDate: Date
    @State private var endDate: Date

    init(schedule: Schedule, onSave: @escaping (Schedule) -> Void, onDelete: (() -> Void)?, onCancel: @escaping () -> Void) {
        self._schedule = State(initialValue: schedule)
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self._startDate = State(initialValue: schedule.startTime.date)
        self._endDate = State(initialValue: schedule.endTime.date)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(onDelete != nil ? "Edit Schedule" : "New Schedule")
                .font(.headline)

            Form {
                TextField("Name", text: $schedule.name)

                DayPicker(selectedDays: $schedule.days)

                DatePicker("Start Time", selection: $startDate, displayedComponents: .hourAndMinute)

                DatePicker("End Time", selection: $endDate, displayedComponents: .hourAndMinute)
            }
            .formStyle(.grouped)

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) { onDelete() }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    schedule.startTime = Schedule.TimeOfDay(from: startDate)
                    schedule.endTime = Schedule.TimeOfDay(from: endDate)
                    onSave(schedule)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(schedule.name.isEmpty || schedule.days.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

struct DayPicker: View {
    @Binding var selectedDays: Set<Schedule.Weekday>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Schedule.Weekday.allCases) { day in
                let isSelected = selectedDays.contains(day)
                Button {
                    if isSelected {
                        selectedDays.remove(day)
                    } else {
                        selectedDays.insert(day)
                    }
                } label: {
                    Text(String(day.shortName.prefix(1)))
                        .font(.caption.weight(.medium))
                        .frame(width: 28, height: 28)
                        .background(isSelected ? Color.accentColor : Color.clear)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
