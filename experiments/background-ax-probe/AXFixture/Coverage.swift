import SwiftUI
import UIKit
import WebKit

// Coverage mode (launch argument -coverage): one screen per toolkit, every control logs its handler through
// Fix.log. A window-level label "lastEvent" stays readable whichever tab is shown.

enum Coverage {
    static func makeRoot(window: UIWindow) -> UIViewController {
        let root: UITabBarController
        if #available(iOS 18.0, *) {
            let tabs = UITabBarController()
            tabs.tabs = [
                UITab(title: "UIKit", image: UIImage(systemName: "square.grid.2x2"), identifier: "tab.uikit") { _ in UINavigationController(rootViewController: UIKitCoverageController()) },
                UITab(title: "Lists", image: UIImage(systemName: "list.bullet"), identifier: "tab.lists") { _ in UINavigationController(rootViewController: ListsCoverageController()) },
                UITab(title: "SwiftUI", image: UIImage(systemName: "swift"), identifier: "tab.swiftui") { _ in UIHostingController(rootView: SwiftUICoverage()) },
                UITab(title: "Web", image: UIImage(systemName: "globe"), identifier: "tab.web") { _ in WebCoverageController() },
            ]
            tabs.delegate = TabLogger.shared
            root = tabs
        } else {
            root = UITabBarController()
        }
        let label = UILabel(); label.accessibilityIdentifier = "lastEvent"; label.text = "0 start"; label.font = .systemFont(ofSize: 9)
        label.translatesAutoresizingMaskIntoConstraints = false
        Fix.label = label
        let sceneLabel = UILabel(); sceneLabel.accessibilityIdentifier = "sceneId"; sceneLabel.text = "scene"; sceneLabel.font = .systemFont(ofSize: 9)
        sceneLabel.translatesAutoresizingMaskIntoConstraints = false; Fix.sceneLabel = sceneLabel
        DispatchQueue.main.async {
            window.addSubview(label); window.addSubview(sceneLabel)
            NSLayoutConstraint.activate([sceneLabel.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor), sceneLabel.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: 4)])
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor), label.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -4)])
        }
        KickProbe.install(root: root)
        return root
    }
}

final class TabLogger: NSObject, UITabBarControllerDelegate {
    static let shared = TabLogger()
    @available(iOS 18.0, *)
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) { Fix.log("tab.select \(selectedTab.identifier)") }
}

final class UIKitCoverageController: UIViewController, UISearchBarDelegate, UIPickerViewDataSource, UIPickerViewDelegate, UITextFieldDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit"; view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "BarItem", primaryAction: UIAction { _ in Fix.log("baritem") })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "cov.baritem"

        var cfg = UIButton.Configuration.filled(); cfg.title = "Configured"
        let configured = UIButton(configuration: cfg, primaryAction: UIAction { _ in Fix.log("configured button") }); configured.accessibilityIdentifier = "cov.configured"
        let actionBtn = UIButton(type: .system); actionBtn.setTitle("UIAction button", for: .normal); actionBtn.addAction(UIAction { _ in Fix.log("uiaction button") }, for: .primaryActionTriggered); actionBtn.accessibilityIdentifier = "cov.uiaction"
        let taBtn = UIButton(type: .system); taBtn.setTitle("Target button", for: .normal); taBtn.addTarget(self, action: #selector(targetTapped), for: .touchUpInside); taBtn.accessibilityIdentifier = "cov.target"
        let sw = UISwitch(); sw.accessibilityIdentifier = "cov.switch"; sw.addAction(UIAction { [weak sw] _ in Fix.log("switch \(sw?.isOn ?? false)") }, for: .valueChanged)
        let stepper = UIStepper(); stepper.accessibilityIdentifier = "cov.stepper"; stepper.addAction(UIAction { [weak stepper] _ in Fix.log("stepper \(Int(stepper?.value ?? 0))") }, for: .valueChanged)
        let page = UIPageControl(); page.numberOfPages = 4; page.accessibilityIdentifier = "cov.page"; page.addAction(UIAction { [weak page] _ in Fix.log("page \(page?.currentPage ?? -1)") }, for: .valueChanged)
        let date = UIDatePicker(); date.datePickerMode = .date; date.preferredDatePickerStyle = .compact; date.accessibilityIdentifier = "cov.date"; date.addAction(UIAction { _ in Fix.log("date changed") }, for: .valueChanged)
        let picker = UIPickerView(); picker.dataSource = self; picker.delegate = self; picker.accessibilityIdentifier = "cov.picker"
        picker.heightAnchor.constraint(equalToConstant: 90).isActive = true
        let search = UISearchBar(); search.delegate = self; search.searchTextField.accessibilityIdentifier = "cov.search"
        let field = UITextField(); field.borderStyle = .roundedRect; field.placeholder = "Return field"; field.accessibilityIdentifier = "cov.field"; field.delegate = self
        field.addAction(UIAction { _ in Fix.log("field primaryAction") }, for: .primaryActionTriggered)
        let menuBtn = UIButton(type: .system); menuBtn.setTitle("Menu button", for: .normal); menuBtn.accessibilityIdentifier = "cov.menu"
        menuBtn.menu = UIMenu(children: [UIAction(title: "MenuItemA") { _ in Fix.log("menu item A") }, UIAction(title: "MenuItemB") { _ in Fix.log("menu item B") }]); menuBtn.showsMenuAsPrimaryAction = true
        let ctx = UILabel(); ctx.text = "Context target"; ctx.isUserInteractionEnabled = true; ctx.isAccessibilityElement = true; ctx.accessibilityIdentifier = "cov.context"; ctx.addInteraction(UIContextMenuInteraction(delegate: CtxDelegate.shared))
        let alertBtn = UIButton(type: .system); alertBtn.setTitle("Present alert", for: .normal); alertBtn.accessibilityIdentifier = "cov.alert"; alertBtn.addAction(UIAction { [weak self] _ in self?.present(style: .alert) }, for: .primaryActionTriggered)
        let sheetBtn = UIButton(type: .system); sheetBtn.setTitle("Present action sheet", for: .normal); sheetBtn.accessibilityIdentifier = "cov.sheet"; sheetBtn.addAction(UIAction { [weak self] _ in self?.present(style: .actionSheet) }, for: .primaryActionTriggered)
        let pushBtn = UIButton(type: .system); pushBtn.setTitle("Push detail", for: .normal); pushBtn.accessibilityIdentifier = "cov.push"; pushBtn.addAction(UIAction { [weak self] _ in self?.navigationController?.pushViewController(DetailController(), animated: false) }, for: .primaryActionTriggered)

        let row1 = UIStackView(arrangedSubviews: [sw, stepper, page]); row1.spacing = 12
        let stack = UIStackView(arrangedSubviews: [configured, actionBtn, taBtn, row1, date, picker, search, field, menuBtn, ctx, alertBtn, sheetBtn, pushBtn])
        stack.axis = .vertical; stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)])
    }
    @objc func targetTapped() { Fix.log("target button") }
    func present(style: UIAlertController.Style) {
        let a = UIAlertController(title: style == .alert ? "CovAlert" : "CovSheet", message: nil, preferredStyle: style)
        a.addAction(UIAlertAction(title: "AlertOK", style: .default) { _ in Fix.log("alert OK") })
        a.addAction(UIAlertAction(title: "AlertOther", style: .default) { _ in Fix.log("alert Other") })
        a.addAction(UIAlertAction(title: "AlertCancel", style: .cancel) { _ in Fix.log("alert Cancel") })
        present(a, animated: false)
    }
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { 5 }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? { "Row \(row)" }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) { Fix.log("picker \(row)") }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { Fix.log("search submit '\(searchBar.text ?? "")'") }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { Fix.log("field shouldReturn '\(textField.text ?? "")'"); return true }
}

final class CtxDelegate: NSObject, UIContextMenuInteractionDelegate {
    static let shared = CtxDelegate()
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        Fix.log("context menu requested")
        return UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: [UIAction(title: "CtxItem") { _ in Fix.log("context item") }]) })
    }
}

final class DetailController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Detail"; view.backgroundColor = .systemBackground; DetailTable.install(in: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "DetailItem", style: .plain, target: self, action: #selector(item))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "cov.detailitem"
    }
    @objc func item() { Fix.log("detail bar item") }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); Fix.log("detail appeared") }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isMovingFromParent { Fix.log("back popped") } }
}

final class ListsCoverageController: UIViewController, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate {
    var dataSource: UICollectionViewDiffableDataSource<Int, Int>!
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Lists"; view.backgroundColor = .systemBackground
        let layout = UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout); cv.delegate = self; cv.accessibilityIdentifier = "cov.collection"
        let reg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, item in
            var c = cell.defaultContentConfiguration(); c.text = "ListCell \(item)"; cell.contentConfiguration = c
            if item == 1 { cell.accessories = [.detail(actionHandler: { Fix.log("cell accessory detail") })] }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, ip, item in cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: item) }
        var snap = NSDiffableDataSourceSnapshot<Int, Int>(); snap.appendSections([0]); snap.appendItems([0, 1, 2]); dataSource.apply(snap)
        let tv = UITableView(frame: .zero, style: .plain); tv.dataSource = self; tv.delegate = self; tv.register(UITableViewCell.self, forCellReuseIdentifier: "c"); tv.accessibilityIdentifier = "cov.table"
        let stack = UIStackView(arrangedSubviews: [cv, tv]); stack.axis = .vertical; stack.distribution = .fillEqually; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { Fix.log("list select \(indexPath.item)") }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        var c = cell.defaultContentConfiguration(); c.text = "TableCell \(indexPath.row)"; c.secondaryText = "configured"; cell.contentConfiguration = c
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { Fix.log("table select \(indexPath.row)") }
}

struct SwiftUICoverage: View {
    @State private var on = false
    @State private var steps = 0
    @State private var level = 0.5
    @State private var choice = 0
    @State private var menuChoice = 0
    @State private var text = ""
    @State private var showSheet = false
    @State private var showAlert = false
    @State private var innerTab = 0
    var body: some View {
        NavigationStack {
            List {
                Button("SUIButton") { Fix.log("swiftui button") }.accessibilityIdentifier("sui.button")
                Toggle("SUIToggle", isOn: $on).accessibilityIdentifier("sui.toggle").onChange(of: on) { _, v in Fix.log("swiftui toggle \(v)") }
                Stepper("SUIStepper \(steps)", value: $steps).accessibilityIdentifier("sui.stepper").onChange(of: steps) { _, v in Fix.log("swiftui stepper \(v)") }
                Slider(value: $level).accessibilityIdentifier("sui.slider").onChange(of: level) { _, v in Fix.log("swiftui slider \(String(format: "%.2f", v))") }
                Picker("SUISegment", selection: $choice) { Text("P0").tag(0); Text("P1").tag(1); Text("P2").tag(2) }.pickerStyle(.segmented).accessibilityIdentifier("sui.segment").onChange(of: choice) { _, v in Fix.log("swiftui segment \(v)") }
                Picker("SUIMenuPicker", selection: $menuChoice) { Text("M0").tag(0); Text("M1").tag(1) }.pickerStyle(.menu).accessibilityIdentifier("sui.menupicker").onChange(of: menuChoice) { _, v in Fix.log("swiftui menu picker \(v)") }
                Menu("SUIMenu") { Button("SUIMenuItem") { Fix.log("swiftui menu item") } }.accessibilityIdentifier("sui.menu")
                Button("SUIShowSheet") { showSheet = true }.accessibilityIdentifier("sui.sheet")
                Button("SUIShowAlert") { showAlert = true }.accessibilityIdentifier("sui.alert")
                TextField("SUIField", text: $text).accessibilityIdentifier("sui.field").onSubmit { Fix.log("swiftui onSubmit '\(text)'") }
                NavigationLink("SUILink") { Text("SUIDestination").onAppear { Fix.log("swiftui link destination") } }.accessibilityIdentifier("sui.link")
                TabView(selection: $innerTab) {
                    Text("InnerA").tabItem { Text("InnerTabA") }.tag(0)
                    Text("InnerB").tabItem { Text("InnerTabB") }.tag(1)
                }.frame(height: 110).onChange(of: innerTab) { _, v in Fix.log("swiftui tabview \(v)") }
            }
            .sheet(isPresented: $showSheet) { Button("SUISheetButton") { Fix.log("swiftui sheet button"); showSheet = false }.accessibilityIdentifier("sui.sheetbutton") }
            .alert("SUIAlert", isPresented: $showAlert) { Button("SUIAlertOK") { Fix.log("swiftui alert OK") }; Button("SUIAlertCancel", role: .cancel) { Fix.log("swiftui alert cancel") } }
        }
    }
}

final class WebCoverageController: UIViewController, WKScriptMessageHandler {
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let cfg = WKWebViewConfiguration(); cfg.userContentController.add(self, name: "log")
        let web = WKWebView(frame: .zero, configuration: cfg); web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14), web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        let html = """
        <html><head><meta name=viewport content="width=device-width"><script>function L(m){window.webkit.messageHandlers.log.postMessage(m)}</script></head>
        <body style="font-size:20px">
        <p><a href="#target" onclick="L('web link')">WebLink</a></p>
        <p><button onclick="L('web button')">WebButton</button></p>
        <p><label><input type=checkbox onchange="L('web checkbox '+this.checked)">WebCheck</label></p>
        <form onsubmit="L('web submit '+document.getElementById('q').value);return false"><input id=q aria-label="WebInput" onchange="L('web input '+this.value)"><input type=submit value="WebSubmit"></form>
        <p id=target>end</p></body></html>
        """
        web.loadHTMLString(html, baseURL: nil)
    }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { Fix.log("\(m.body)") }
}

final class DetailTable: NSObject, UITableViewDataSource {
    static let shared = DetailTable()
    static func install(in vc: UIViewController) {
        let t = UITableView(frame: .zero, style: .plain); t.accessibilityIdentifier = "cov.detailtable"
        t.dataSource = shared; t.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        t.translatesAutoresizingMaskIntoConstraints = false; vc.view.addSubview(t)
        NSLayoutConstraint.activate([t.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 40), t.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor), t.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor), t.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)])
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 40 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        c.textLabel?.text = "Detail row \(indexPath.row)"; c.accessibilityIdentifier = "DetailRow \(indexPath.row)"; return c
    }
}

// Diagnostic only (launch argument -kick <mode>): after the scene enters the background, report the navigation
// state through Fix.log, then run one in-app layout call so the test can tell what a pending pop is waiting for.
enum KickProbe {
    static var token: NSObjectProtocol?
    static func install(root: UITabBarController) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-kick"), i + 1 < args.count else { return }
        let mode = args[i + 1]
        token = NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            func nav() -> UINavigationController? { root.selectedViewController as? UINavigationController }
            func state(_ tag: String) {
                guard let n = nav() else { Fix.log("K \(tag) no nav"); return }
                let d = (n.value(forKey: "needsDeferredTransition") as? NSNumber)?.intValue ?? -1
                Fix.log("K \(tag) \(mode) count \(n.viewControllers.count) navNL \(n.view.layer.needsLayout() ? 1 : 0) barNL \(n.navigationBar.layer.needsLayout() ? 1 : 0) deferred \(d) coord \(n.transitionCoordinator == nil ? 0 : 1)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { state("t5") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard let n = nav() else { return }
                switch mode {
                case "navView": n.view.layoutIfNeeded()
                case "navBar": n.navigationBar.layoutIfNeeded()
                case "table": n.topViewController?.view.subviews.first(where: { $0 is UITableView })?.layoutIfNeeded()
                case "window": n.view.window?.layoutIfNeeded()
                case "flush": CATransaction.flush()
                case "needs": n.view.window?.setNeedsLayout()
                default: break
                }
                state("t8kick")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) { state("t11") }
        }
    }
}
