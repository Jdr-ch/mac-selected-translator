import AppKit

@MainActor
final class IPhoneLocationWindowController: NSWindowController {
    private let deviceDiscovery: IPhoneDeviceDiscoveryService
    private let locationService: IPhoneLocationService
    private let locationStore = IPhoneLocationStore()
    /// Mirrors the popup order so its selected index resolves to the same device identity.
    private var devices: [ConnectedIPhone] = []
    /// Blocks duplicate refreshes while the one-shot usbmux discovery process is running.
    private var isDiscovering = false
    /// Preserves usbmux failures across the normal control refresh that follows discovery.
    private var discoveryError: String?

    private let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton()
    private let latitudeField = NSTextField(string: "")
    private let longitudeField = NSTextField(string: "")
    private let statusIndicator = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在读取设备...")
    private let currentLocationButton = NSButton(title: "获取当前定位", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复真实定位", target: nil, action: nil)
    private let setLocationButton = NSButton(title: "使用此定位", target: nil, action: nil)
    private let savedLocationNameField = NSTextField(string: "")
    private let saveLocationButton = NSButton(title: "保存常用定位", target: nil, action: nil)
    private let savedLocationsStack = NSStackView()
    private let savedLocationsScrollView = NSScrollView()
    private var savedLocations: [SavedIPhoneLocation] = []

    init(projectRoot: URL?) {
        let paths = IPhoneLocationPaths(projectRoot: projectRoot)
        self.deviceDiscovery = IPhoneDeviceDiscoveryService(paths: paths)
        self.locationService = IPhoneLocationService(paths: paths)

        let contentSize = NSSize(width: 620, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iPhone 定位"
        window.isReleasedWhenClosed = false
        // Keep Auto Layout's fitting size from collapsing the tool window around its controls.
        window.contentMinSize = contentSize
        super.init(window: window)

        configureControls()
        layoutControls()
        bindState()
        savedLocations = locationStore.load()
        reloadSavedLocations()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the retained tool window and refreshes USB devices whenever the menu command is used.
    func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDevices()
    }

    /// Gives an active simulation session a chance to clear the override before app termination.
    func shutdown() {
        locationService.shutdown()
    }

    /// Resolves the popup index against the current discovery snapshot.
    private var selectedDevice: ConnectedIPhone? {
        let index = devicePopUp.indexOfSelectedItem
        guard devices.indices.contains(index) else {
            return nil
        }
        return devices[index]
    }

    /// Wires all panel actions once while the retained window is created.
    private func configureControls() {
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceSelectionChanged)

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新设备")
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.toolTip = "刷新设备"
        refreshButton.target = self
        refreshButton.action = #selector(refreshDevices)

        latitudeField.placeholderString = "31.2304"
        longitudeField.placeholderString = "121.4737"
        statusIndicator.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        currentLocationButton.image = NSImage(systemSymbolName: "location.circle", accessibilityDescription: nil)
        currentLocationButton.imagePosition = .imageLeading
        currentLocationButton.bezelStyle = .rounded
        currentLocationButton.target = self
        currentLocationButton.action = #selector(readCurrentLocation)

        restoreButton.image = NSImage(systemSymbolName: "location.slash", accessibilityDescription: nil)
        restoreButton.imagePosition = .imageLeading
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreRealLocation)

        setLocationButton.image = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
        setLocationButton.imagePosition = .imageLeading
        setLocationButton.bezelStyle = .rounded
        setLocationButton.keyEquivalent = "\r"
        setLocationButton.target = self
        setLocationButton.action = #selector(startSimulation)

        savedLocationNameField.placeholderString = "地名，例如：公司"
        saveLocationButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        saveLocationButton.imagePosition = .imageLeading
        saveLocationButton.bezelStyle = .rounded
        saveLocationButton.target = self
        saveLocationButton.action = #selector(saveCurrentLocation)

        // The scroll document follows the viewport width, not its initial zero-sized frame.
        savedLocationsStack.translatesAutoresizingMaskIntoConstraints = false
        savedLocationsStack.orientation = .vertical
        savedLocationsStack.alignment = .leading
        savedLocationsStack.spacing = 6
        savedLocationsStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        savedLocationsScrollView.translatesAutoresizingMaskIntoConstraints = false
        savedLocationsScrollView.borderType = .bezelBorder
        savedLocationsScrollView.hasVerticalScroller = true
        savedLocationsScrollView.autohidesScrollers = true
        savedLocationsScrollView.documentView = savedLocationsStack
    }

    /// Keeps device selection, coordinate inputs, status, and actions in fixed scan order.
    private func layoutControls() {
        guard let contentView = window?.contentView else {
            return
        }

        let deviceRow = NSStackView(views: [devicePopUp, refreshButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 8
        devicePopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refreshButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "设备"), deviceRow],
            [NSTextField(labelWithString: "纬度"), latitudeField],
            [NSTextField(labelWithString: "经度"), longitudeField]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let statusRow = NSStackView(views: [statusIndicator, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        statusIndicator.setContentHuggingPriority(.required, for: .horizontal)

        let actionRow = NSStackView(views: [currentLocationButton, restoreButton, setLocationButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually
        actionRow.spacing = 10

        let savedLocationEditor = NSStackView(views: [savedLocationNameField, saveLocationButton])
        savedLocationEditor.orientation = .horizontal
        savedLocationEditor.spacing = 10
        savedLocationNameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveLocationButton.setContentHuggingPriority(.required, for: .horizontal)

        let savedLocationsTitle = NSTextField(labelWithString: "常用定位")
        savedLocationsTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let savedLocationsSection = NSStackView(views: [savedLocationsTitle, savedLocationEditor, savedLocationsScrollView])
        savedLocationsSection.orientation = .vertical
        savedLocationsSection.alignment = .leading
        savedLocationsSection.spacing = 8

        let contentStack = NSStackView(views: [grid, statusRow, actionRow, savedLocationsSection])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 22
        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            grid.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            savedLocationsSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            savedLocationEditor.widthAnchor.constraint(equalTo: savedLocationsSection.widthAnchor),
            savedLocationsScrollView.widthAnchor.constraint(equalTo: savedLocationsSection.widthAnchor),
            savedLocationsScrollView.heightAnchor.constraint(equalToConstant: 150),
            savedLocationsStack.leadingAnchor.constraint(equalTo: savedLocationsScrollView.contentView.leadingAnchor),
            savedLocationsStack.topAnchor.constraint(equalTo: savedLocationsScrollView.contentView.topAnchor),
            savedLocationsStack.widthAnchor.constraint(equalTo: savedLocationsScrollView.contentView.widthAnchor),
            latitudeField.heightAnchor.constraint(equalToConstant: 28),
            longitudeField.heightAnchor.constraint(equalToConstant: 28),
            actionRow.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    /// Reflects service state in controls and fills both inputs after a phone reading succeeds.
    private func bindState() {
        locationService.onStateChange = { [weak self] state in
            if case .currentLocation(_, let location) = state {
                self?.latitudeField.stringValue = location.coordinate.latitudeInputText
                self?.longitudeField.stringValue = location.coordinate.longitudeInputText
            }
            self?.updateControls()
        }
        updateControls()
    }

    /// Adds the current coordinate to the persisted presets after validating both fields.
    @objc private func saveCurrentLocation() {
        let name = savedLocationNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showStatus("请输入常用定位的地名。", color: .systemRed)
            return
        }
        do {
            let coordinate = try IPhoneCoordinate.parse(
                latitude: latitudeField.stringValue,
                longitude: longitudeField.stringValue
            )
            savedLocations.append(SavedIPhoneLocation(name: name, coordinate: coordinate))
            locationStore.save(savedLocations)
            savedLocationNameField.stringValue = ""
            reloadSavedLocations()
            showStatus("已保存常用定位：\\(name)。", color: .systemGreen)
        } catch {
            showStatus(error.localizedDescription, color: .systemRed)
        }
    }

    /// Rebuilds the compact preset list so each row always carries its own stable identifier.
    private func reloadSavedLocations() {
        savedLocationsStack.arrangedSubviews.forEach { view in
            savedLocationsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if savedLocations.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "暂无常用定位，请输入地名后保存。")
            emptyLabel.textColor = .secondaryLabelColor
            savedLocationsStack.addArrangedSubview(emptyLabel)
            return
        }
        for location in savedLocations {
            let nameLabel = NSTextField(labelWithString: location.name)
            nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let coordinateLabel = NSTextField(labelWithString: location.coordinate.displayText)
            coordinateLabel.textColor = .secondaryLabelColor
            let details = NSStackView(views: [nameLabel, coordinateLabel])
            details.orientation = .vertical
            details.alignment = .leading
            details.spacing = 2

            let useButton = NSButton(title: "使用", target: self, action: #selector(useSavedLocation(_:)))
            useButton.image = NSImage(systemSymbolName: "arrow.down.left", accessibilityDescription: nil)
            useButton.imagePosition = .imageLeading
            useButton.bezelStyle = .rounded
            useButton.identifier = NSUserInterfaceItemIdentifier(location.id.uuidString)

            let deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "删除常用定位")!, target: self, action: #selector(deleteSavedLocation(_:)))
            deleteButton.imagePosition = .imageOnly
            deleteButton.bezelStyle = .texturedRounded
            deleteButton.toolTip = "删除常用定位"
            deleteButton.identifier = NSUserInterfaceItemIdentifier(location.id.uuidString)

            let row = NSStackView(views: [details, useButton, deleteButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            details.setContentHuggingPriority(.defaultLow, for: .horizontal)
            useButton.setContentHuggingPriority(.required, for: .horizontal)
            deleteButton.setContentHuggingPriority(.required, for: .horizontal)
            savedLocationsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: savedLocationsStack.widthAnchor, constant: -16).isActive = true
        }
    }

    @objc private func useSavedLocation(_ sender: NSButton) {
        guard
            let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString),
            let location = savedLocations.first(where: { $0.id == id })
        else {
            return
        }
        latitudeField.stringValue = location.coordinate.latitudeInputText
        longitudeField.stringValue = location.coordinate.longitudeInputText
        showStatus("已载入常用定位：\\(location.name)。", color: .systemBlue)
    }

    @objc private func deleteSavedLocation(_ sender: NSButton) {
        guard
            let idString = sender.identifier?.rawValue,
            let id = UUID(uuidString: idString)
        else {
            return
        }
        savedLocations.removeAll { $0.id == id }
        locationStore.save(savedLocations)
        reloadSavedLocations()
    }

    /// Refreshes paired USB devices and preserves the previous UDID when it is still present.
    @objc private func refreshDevices() {
        guard !isDiscovering else {
            return
        }

        isDiscovering = true
        discoveryError = nil
        let previousDeviceID = selectedDevice?.id
        updateControls()
        deviceDiscovery.loadDevices { [weak self] result in
            guard let self else {
                return
            }
            self.isDiscovering = false
            switch result {
            case .success(let devices):
                self.devices = devices
                self.reloadDeviceMenu(selectedDeviceID: previousDeviceID)
            case .failure(let error):
                self.devices = []
                self.discoveryError = error.localizedDescription
                self.reloadDeviceMenu(selectedDeviceID: nil)
            }
            self.updateControls()
        }
    }

    /// Rebuilds the popup while retaining the previous UDID rather than a stale row index.
    private func reloadDeviceMenu(selectedDeviceID: String?) {
        devicePopUp.removeAllItems()
        if devices.isEmpty {
            devicePopUp.addItem(withTitle: "未发现已配对的 iPhone")
            return
        }
        for device in devices {
            devicePopUp.addItem(withTitle: device.displayName)
        }
        if let selectedDeviceID, let index = devices.firstIndex(where: { $0.id == selectedDeviceID }) {
            devicePopUp.selectItem(at: index)
        } else {
            devicePopUp.selectItem(at: 0)
        }
    }

    /// Re-evaluates action availability against the newly selected phone's transport and iOS version.
    @objc private func deviceSelectionChanged() {
        updateControls()
    }

    /// Validates decimal-degree fields before opening a device session, preventing ambiguous input.
    @objc private func startSimulation() {
        guard let device = readySelectedDevice() else {
            return
        }
        do {
            let coordinate = try IPhoneCoordinate.parse(
                latitude: latitudeField.stringValue,
                longitude: longitudeField.stringValue
            )
            locationService.startSimulation(device: device, coordinate: coordinate)
        } catch {
            showStatus(error.localizedDescription, color: .systemRed)
        }
    }

    /// Clears both this app's retained session and compatible external DVT location overrides.
    @objc private func restoreRealLocation() {
        guard let device = readySelectedDevice() else {
            return
        }
        locationService.restoreRealLocation(on: device)
    }

    /// Requests a fresh, request-scoped CLLocation from the signed companion installed on the phone.
    @objc private func readCurrentLocation() {
        guard let device = readySelectedDevice() else {
            return
        }
        locationService.requestCurrentLocation(from: device)
    }

    /// Gates every device action on a selected USB iPhone that supports the native tunnel.
    private func readySelectedDevice() -> ConnectedIPhone? {
        guard let device = selectedDevice else {
            showStatus("请先连接并选择一台 iPhone。", color: .systemRed)
            return nil
        }
        guard device.isReadyForDeveloperLocation else {
            showStatus(device.readinessMessage, color: .systemOrange)
            return nil
        }
        return device
    }

    /// Serializes discovery and location operations so conflicting device actions cannot overlap.
    private func updateControls() {
        let deviceReady = selectedDevice?.isReadyForDeveloperLocation == true
        let isBusy: Bool
        let isSimulating: Bool

        switch locationService.state {
        case .startingSimulation, .stoppingSimulation, .readingCurrentLocation:
            isBusy = true
            isSimulating = false
        case .simulating:
            isBusy = false
            isSimulating = true
        case .idle, .currentLocation, .failed:
            isBusy = false
            isSimulating = false
        }

        devicePopUp.isEnabled = !isDiscovering && !isBusy && !isSimulating && !devices.isEmpty
        refreshButton.isEnabled = !isDiscovering && !isBusy && !isSimulating
        latitudeField.isEnabled = !isBusy && !isSimulating
        longitudeField.isEnabled = !isBusy && !isSimulating
        currentLocationButton.isEnabled = deviceReady && !isBusy && !isSimulating
        restoreButton.isEnabled = deviceReady && !isBusy
        setLocationButton.isEnabled = deviceReady && !isBusy && !isSimulating

        if isDiscovering {
            showStatus("正在读取已配对的 iPhone...", color: .secondaryLabelColor)
            return
        }

        switch locationService.state {
        case .idle:
            showIdleStatus()
        case .startingSimulation:
            showStatus("正在连接 iPhone 开发者定位服务...", color: .systemBlue)
        case .simulating(let device, let coordinate):
            showStatus("\(device.name) 正在使用模拟定位：\(coordinate.displayText)", color: .systemGreen)
        case .stoppingSimulation:
            showStatus("正在清除模拟定位...", color: .systemBlue)
        case .readingCurrentLocation:
            showStatus("正在从 iPhone 获取当前定位...", color: .systemBlue)
        case .currentLocation(let device, let location):
            showStatus(
                "已读取 \(device.name)：\(location.coordinate.displayText)，精度 ±\(Int(location.horizontalAccuracy.rounded())) 米。",
                color: .systemGreen
            )
        case .failed(let message):
            showStatus(message, color: .systemRed)
        }
    }

    /// Shows discovery errors first, then readiness guidance for the selected or missing device.
    private func showIdleStatus() {
        if let discoveryError {
            showStatus(discoveryError, color: .systemRed)
        } else if let selectedDevice {
            showStatus(selectedDevice.readinessMessage, color: .systemGreen)
        } else {
            showStatus("通过 USB 连接、解锁并信任 iPhone 后刷新。", color: .secondaryLabelColor)
        }
    }

    /// Updates the indicator and message together so success, progress, and failure remain aligned.
    private func showStatus(_ message: String, color: NSColor) {
        statusIndicator.textColor = color
        statusLabel.textColor = color
        statusLabel.stringValue = message
    }
}
