import XCTest
@testable import PokiCore

final class SensitivityTests: XCTestCase {
    private let punctuatedActions = [
        "Tap to pay $12.00", "Tap to pay $1,200.00",
        "Tap to pay 12.00元/次",
    ]

    private func reason(_ label: String, type: String = "Button", in elements: [Element]? = nil) -> String? {
        let element = Element(type: type, label: label, value: nil, identifier: nil,
                              frame: Rect(x: 0, y: 0, width: 100, height: 44), depth: 1, node: 2, end: 2)
        return SensitivityRules().reason(
            touching: element,
            typing: false, app: Foreground(bundleID: "com.apple.mobilemail", name: "Mail"),
            secureOnScreen: false, in: elements ?? [element])
    }

    func testLongActionButtonsStillRequireApproval() {
        for label in ["Complete purchase of 3 items", "Tap here to complete the payment",
                      "Open details and then pay"] {
            XCTAssertNotNil(reason(label), label)
        }
        // Deleting on an ordinary page is allowed; compact delete inside a dialog still asks.
        XCTAssertNil(reason("Tap here to delete this photo permanently"))
        let alert = Element(type: "Alert", label: nil, value: nil, identifier: nil,
                            frame: Rect(x: 40, y: 300, width: 310, height: 180), depth: 1, node: 2, end: 3)
        let deleteButton = Element(type: "Button", label: "Delete Photo", value: nil, identifier: nil,
                                   frame: Rect(x: 56, y: 420, width: 278, height: 44), depth: 2, node: 3, end: 3)
        XCTAssertEqual(
            SensitivityRules().reason(
                touching: deleteButton, typing: false,
                app: Foreground(bundleID: "com.apple.mobilemail", name: "Mail"),
                secureOnScreen: false, in: [alert, deleteButton]
            ),
            "deleting (\"delete\")"
        )
    }

    func testTraditionalChineseActionsRequireApproval() {
        for label in ["購買", "訂閱", "轉賬", "轉帳", "發送", "回覆", "發布", "撥打"] {
            XCTAssertNotNil(reason(label), label)
        }
        // Traditional Chinese delete labels require approval inside a confirmation dialog or menu.
        for label in ["刪除", "還原"] {
            XCTAssertNil(reason(label), label)
            let menu = Element(type: "Menu", label: nil, value: nil, identifier: nil,
                               frame: Rect(x: 180, y: 120, width: 190, height: 120), depth: 1, node: 2, end: 3)
            let button = Element(type: "Button", label: label, value: nil, identifier: nil,
                                 frame: Rect(x: 180, y: 164, width: 190, height: 44), depth: 2, node: 3, end: 3)
            XCTAssertNotNil(
                SensitivityRules().reason(
                    touching: button, typing: false,
                    app: Foreground(bundleID: "com.apple.mobilemail", name: "Mail"),
                    secureOnScreen: false, in: [menu, button]
                ),
                label
            )
        }
    }

    func testDescriptiveRowsKeepTheirFalsePositiveGuards() {
        for (type, label) in [("Image", "Contact photo for Best Buy"),
                              ("Cell", "Best Buy, Your order has shipped, Yesterday")] {
            XCTAssertNil(reason(label, type: type), label)
        }
        for label in ["Display & Brightness", "PayPal", "buy1", "1pay", "repayment"] {
            XCTAssertNil(reason(label), label)
        }
    }

    /// A mix of a message and a money move must be reported as the payment. The app is a messaging one, so
    /// if `reason` consulted sending before payments this label would come back as a sent message instead.
    func testAPaymentIsReportedInsteadOfASentMessageWhenBothAreInTheLabel() {
        let why = reason("Please send money to Sam and reply afterwards")
        XCTAssertNotNil(why)
        XCTAssertTrue((why ?? "").contains("a payment"), "expected a payment, got \(why ?? "nil")")
    }

    func testLaterWholeWordMatchIsNotHiddenByAnEarlierSubstring() {
        XCTAssertNotNil(reason("Buying help: buy this item now"))
        XCTAssertNotNil(reason("Display details, then pay for this order"))
    }

    func testShortActionsWithAmountsAndDatedNamesRequireApproval() {
        for label in punctuatedActions {
            for type in ["Text", "Other", "Cell", "Link", "StaticText", "Image", "TextField", "Unknown"] {
                XCTAssertNotNil(reason(label, type: type), label)
            }
        }
    }

    func testHyphenatedRowsKeepTheBasesApprovalProtection() {
        for label in ["Tap-here-to-see-this-payment-receipt", "Tap-here-to-see-the-buy-receipt"] {
            XCTAssertNotNil(reason(label, type: "Cell"), label)
        }
    }

    func testStructuredNonButtonPaymentSendsNothingBeforeApproval() async {
        let wda = FakeWDA()
        wda.source([("Link", "Tap to pay $12.00")], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("1 Link"), look.text)
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testNumberedOCRActionSendsNothingBeforeApproval() async {
        for label in punctuatedActions {
            let (core, wda, host) = makeCore {
                $0.readTimeout = 0.5
                $0.approvalWait = 0
            }
            _ = await core.call("look", [:])
            host.texts.value = [RecognizedText(text: label,
                                              box: Rect(x: 0.25, y: 0.9, width: 0.5, height: 0.05))]
            wda.set("GET /source") { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return (200, ["value": .null])
            }
            let look = await core.call("look", [:])
            XCTAssertTrue(look.text.contains("1 Text"), look.text)
            XCTAssertTrue(look.text.contains(label), look.text)
            let tap = await core.call("do", ["actions": [["tap": 1]]])
            XCTAssertTrue(tap.text.contains("approval_required"), tap.text)
            XCTAssertNotNil(core.pendingApproval)
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
        }
    }

    func testVoiceActionClearanceRequiresApproval() async {
        for label in punctuatedActions {
            let (core, _, _) = makeCore()
            let clearance = await core.clearTap(on: label, inApp: "example.shop",
                                               named: "Shop", waiting: 0.2)
            guard case .unanswered = clearance else {
                XCTFail("Expected a pending approval for \(label), got \(clearance)")
                continue
            }
            XCTAssertFalse(clearance.mayTap)
            XCTAssertNil(core.pendingApproval)
        }
    }

    func testLongPaymentButtonSendsNothingBeforeApproval() async {
        let wda = FakeWDA()
        wda.source([("Button", "Complete purchase of 3 items")], app: "Shop")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0 }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertTrue(result.text.contains("approval_required"), result.text)
        XCTAssertNotNil(core.pendingApproval)
        XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty)
    }

    func testCtripFullScreenContainerWithClearDoesNotRequireApproval() async {
        let repeatedCard = " 南山区 · 近南头古城 酒店房费优惠 积分再抵¥21 免费停车场 洗衣房 免费健身室 4.7 超棒 617点评 7330收藏 ¥422 起 白银贵宾价 门店首单 3项优惠"
        let ctripLabel = "最高使用2136积分抵 ¥21 积分抵房费 每100积分=¥1 打开开关看积分抵后价"
            + String(repeating: repeatedCard, count: 16)
            + " 以上是符合条件的酒店，修改可重新查询 清空 ¥300-¥350 筛选 完成"
        XCTAssertGreaterThan(ctripLabel.count, 1200)

        let wda = FakeWDA()
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "ctrip.wireless", "name": "携程旅行"]]) }
        wda.tree([Node("Other", ctripLabel, [0, 0, 402, 874])], app: "携程旅行")
        let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.approvalMode = { .off } }
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]]])
        XCTAssertFalse(result.text.contains("approval_required"), result.text)
        XCTAssertNil(core.pendingApproval)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)

        // Even inside an Alert container, the oversized long CJK label must not trigger approval.
        let alert = Element(type: "Alert", label: nil, value: nil, identifier: nil,
                            frame: Rect(x: 0, y: 0, width: 402, height: 874), depth: 1, node: 2, end: 3)
        let container = Element(type: "Other", label: ctripLabel, value: nil, identifier: nil,
                                frame: Rect(x: 0, y: 0, width: 402, height: 874), depth: 2, node: 3, end: 3)
        let ctrip = Foreground(bundleID: "ctrip.wireless", name: "携程旅行")
        XCTAssertNil(SensitivityRules().reason(touching: container, typing: false, app: ctrip, secureOnScreen: false, in: [alert, container]))
    }

    func testVoiceClearTapProtectsCompactDeletesAndAllowsLongChineseContainers() async {
        let repeatedCard = " 南山区 · 近南头古城 酒店房费优惠 积分再抵¥21 免费停车场 洗衣房 免费健身室 4.7 超棒 617点评 7330收藏 ¥422 起 白银贵宾价 门店首单 3项优惠"
        let ctripLabel = "最高使用2136积分抵 ¥21 积分抵房费 每100积分=¥1 打开开关看积分抵后价"
            + String(repeating: repeatedCard, count: 16)
            + " 以上是符合条件的酒店，修改可重新查询 清空 ¥300-¥350 筛选 完成"

        let (core, _, _) = makeCore { $0.approvalMode = { .off } }
        for compactDelete in ["Delete", "删除"] {
            let clearance = await core.clearTap(on: compactDelete, inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.05)
            guard case .unanswered(let reason) = clearance else {
                XCTFail("Expected bridged voice tap on \(compactDelete) to require approval, got \(clearance)")
                continue
            }
            XCTAssertFalse(clearance.mayTap, compactDelete)
            XCTAssertTrue(reason.contains("deleting"), reason)
        }

        for safeText in [
            ctripLabel,
            "最高使用2136积分抵 ¥21 门店首单优惠 支持微信支付与支付宝付款 退改无忧 详情见规则说明",
            "张三：刚才那份文件我已经发送给你了，收到后请及时回复并确认删除草稿",
        ] {
            let clearance = await core.clearTap(on: safeText, inApp: "ctrip.wireless", named: "携程旅行", waiting: 0.05)
            XCTAssertEqual(clearance, .clear, safeText)
            XCTAssertTrue(clearance.mayTap, safeText)
        }
    }

    func testOrdinaryPageClearAndDeleteButtonsDoNotRequireApproval() async {
        let cases: [(type: String, label: String)] = [
            ("Button", "清空"),
            ("StaticText", "清空"),
            ("Button", "删除"),
            ("Other", "删除"),
            ("Button", "Delete"),
            ("Button", "Delete Photo"),
        ]
        for item in cases {
            let wda = FakeWDA()
            wda.tree([Node(item.type, item.label, [16, 120, 120, 44])], app: "携程旅行")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.approvalMode = { .off } }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["tap": 1]]])
            XCTAssertFalse(result.text.contains("approval_required"), "\(item.type) \(item.label): \(result.text)")
            XCTAssertNil(core.pendingApproval, "\(item.type) \(item.label)")
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, "\(item.type) \(item.label)")
        }

        // A full-screen edit page with a top Cancel and bottom Delete is not a confirmation dialog.
        let pageWDA = FakeWDA()
        pageWDA.tree([
            Node("Other", nil, [0, 0, 402, 874], [
                Node("NavigationBar", nil, [0, 44, 402, 44], [
                    Node("Button", "取消", [16, 44, 60, 44]),
                ]),
                Node("Cell", "第一条记录", [0, 120, 402, 44]),
                Node("Cell", "第二条记录", [0, 164, 402, 44]),
                Node("Toolbar", nil, [0, 810, 402, 64], [
                    Node("Button", "删除", [310, 818, 76, 44]),
                ]),
            ]),
        ], app: "Notes")
        let (pageCore, _, _) = makeCore(pageWDA) { $0.approvalWait = 0; $0.approvalMode = { .off } }
        let look = await pageCore.call("look", [:])
        XCTAssertTrue(look.text.contains("4 Button \"删除\""), look.text)
        let tap = await pageCore.call("do", ["actions": [["tap": 4]]])
        XCTAssertFalse(tap.text.contains("approval_required"), tap.text)
        XCTAssertNil(pageCore.pendingApproval)
        XCTAssertEqual(pageWDA.bodies("POST /wda/tap").count, 1)

        // A compact inline edit group with Cancel and Delete on an ordinary page is not a confirmation dialog.
        let inlineWDA = FakeWDA()
        inlineWDA.tree([
            Node("NavigationBar", "编辑日程", [0, 44, 402, 44]),
            Node("Other", nil, [16, 200, 370, 120], [
                Node("StaticText", "编辑备注", [24, 208, 200, 28]),
                Node("Button", "取消", [24, 256, 150, 44]),
                Node("Button", "删除", [212, 256, 150, 44]),
            ]),
            Node("Cell", "其他日程", [0, 360, 402, 44]),
        ], app: "Calendar")
        let (inlineCore, _, _) = makeCore(inlineWDA) { $0.approvalWait = 0; $0.approvalMode = { .off } }
        let inlineLook = await inlineCore.call("look", [:])
        XCTAssertTrue(inlineLook.text.contains("4 Button \"删除\""), inlineLook.text)
        let inlineTap = await inlineCore.call("do", ["actions": [["tap": 4]]])
        XCTAssertFalse(inlineTap.text.contains("approval_required"), inlineTap.text)
        XCTAssertNil(inlineCore.pendingApproval)
        XCTAssertEqual(inlineWDA.bodies("POST /wda/tap").count, 1)
    }

    func testDeleteInsideConfirmationDialogsRequiresApproval() async {
        let dialogs: [(name: String, nodes: [Node], deleteRef: Int)] = [
            (
                "Alert Chinese",
                [Node("Alert", nil, [40, 300, 310, 180], [
                    Node("StaticText", "确定要删除吗？", [56, 320, 278, 44]),
                    Node("Button", "取消", [56, 420, 130, 44]),
                    Node("Button", "删除", [204, 420, 130, 44]),
                ])],
                3
            ),
            (
                "Sheet English",
                [Node("Sheet", nil, [0, 620, 390, 224], [
                    Node("Button", "Delete", [16, 660, 358, 56]),
                    Node("Button", "Cancel", [16, 730, 358, 56]),
                ])],
                1
            ),
            (
                "Dialog English",
                [Node("Dialog", nil, [40, 300, 310, 180], [
                    Node("Button", "Delete", [204, 420, 130, 44]),
                    Node("Button", "Cancel", [56, 420, 130, 44]),
                ])],
                1
            ),
            (
                "Custom confirm box with Delete and Cancel",
                [Node("Other", nil, [40, 300, 310, 180], [
                    Node("StaticText", "删除这条记录？", [56, 320, 278, 44]),
                    Node("Button", "取消", [56, 420, 130, 44]),
                    Node("Button", "删除", [204, 420, 130, 44]),
                ])],
                3
            ),
        ]
        for dialog in dialogs {
            let wda = FakeWDA()
            wda.tree(dialog.nodes, app: "Photos")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.approvalMode = { .off } }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["tap": .number(Double(dialog.deleteRef))]]])
            XCTAssertTrue(result.text.contains("approval_required"), "\(dialog.name): \(result.text)")
            XCTAssertTrue(core.pendingApproval?.reason.contains("deleting") == true, "\(dialog.name): \(core.pendingApproval?.reason ?? "nil")")
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, dialog.name)
        }
    }

    func testDeleteInsidePopupMenusRequiresApproval() async {
        let menus: [(name: String, nodes: [Node], deleteRef: Int)] = [
            (
                "Menu Chinese",
                [Node("Menu", nil, [180, 120, 190, 120], [
                    Node("Button", "分享", [180, 120, 190, 44]),
                    Node("Button", "删除", [180, 164, 190, 44]),
                ])],
                2
            ),
            (
                "Popover English",
                [Node("Popover", nil, [180, 120, 190, 120], [
                    Node("Button", "Delete", [180, 164, 190, 44]),
                ])],
                1
            ),
            (
                "MenuItem Chinese",
                [Node("MenuItem", "删除", [180, 164, 190, 44])],
                1
            ),
            (
                "MenuItem English",
                [Node("MenuItem", "Delete", [180, 164, 190, 44])],
                1
            ),
            (
                "MenuItem ancestor wrapping Chinese Button",
                [Node("MenuItem", nil, [180, 164, 190, 44], [
                    Node("Button", "删除", [180, 164, 190, 44]),
                ])],
                1
            ),
            (
                "MenuItem ancestor wrapping English StaticText",
                [Node("MenuItem", nil, [180, 164, 190, 44], [
                    Node("StaticText", "Delete", [180, 164, 190, 44]),
                ])],
                1
            ),
        ]
        for menu in menus {
            let wda = FakeWDA()
            wda.tree(menu.nodes, app: "Files")
            let (core, _, _) = makeCore(wda) { $0.approvalWait = 0; $0.approvalMode = { .off } }
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": [["tap": .number(Double(menu.deleteRef))]]])
            XCTAssertTrue(result.text.contains("approval_required"), "\(menu.name): \(result.text)")
            XCTAssertTrue(core.pendingApproval?.reason.contains("deleting") == true, "\(menu.name): \(core.pendingApproval?.reason ?? "nil")")
            XCTAssertTrue(wda.bodies("POST /wda/tap").isEmpty, menu.name)
        }
    }

    func testChineseLongContainerWithPaymentOrSendingWordsDoesNotRequireApproval() {
        let rules = SensitivityRules()
        let wechat = Foreground(bundleID: "com.tencent.xin", name: "WeChat")
        let longCases: [(type: String, label: String, frame: Rect)] = [
            ("Other", "最高使用2136积分抵 ¥21 门店首单优惠 支持微信支付与支付宝付款 退改无忧 详情见规则说明", Rect(x: 0, y: 0, width: 402, height: 874)),
            ("Cell", "招商银行：您尾号1234的银行卡完成一笔购买交易，请点击查看账单与支付详情", Rect(x: 0, y: 120, width: 390, height: 72)),
            ("StaticText", "张三：刚才那份文件我已经发送给你了，收到后请及时回复并确认发布时间", Rect(x: 16, y: 200, width: 358, height: 60)),
            ("Other", "客服服务时间每日9点至21点，如有疑问请随时拨打客服电话或在线留言", Rect(x: 0, y: 300, width: 390, height: 120)),
        ]
        for item in longCases {
            let element = Element(type: item.type, label: item.label, value: nil, identifier: nil, frame: item.frame, depth: 1)
            XCTAssertNil(rules.reason(touching: element, typing: false, app: wechat, secureOnScreen: false), item.label)
        }

        // Compact Chinese action controls for payment, sending, and calling still require approval.
        for (type, label) in [("Button", "确认支付"), ("Button", "购买"), ("Other", "确认支付"), ("Button", "发送"), ("Button", "拨打")] {
            let element = Element(type: type, label: label, value: nil, identifier: nil, frame: Rect(x: 16, y: 400, width: 160, height: 44), depth: 1)
            XCTAssertNotNil(rules.reason(touching: element, typing: false, app: wechat, secureOnScreen: false), "\(type) \(label)")
        }

        // Context menu container identified by UIKit identifier also triggers delete approval via node...end containment.
        let contextMenu = Element(
            type: "Other", label: nil, value: nil, identifier: "UIContextMenuView",
            frame: Rect(x: 160, y: 200, width: 200, height: 140), depth: 1, node: 2, end: 3
        )
        let menuDelete = Element(
            type: "Button", label: "删除", value: nil, identifier: nil,
            frame: Rect(x: 160, y: 244, width: 200, height: 44), depth: 2, node: 3, end: 3
        )
        XCTAssertEqual(
            rules.reason(touching: menuDelete, typing: false, app: wechat, secureOnScreen: false, in: [contextMenu, menuDelete]),
            "deleting (\"删除\")"
        )
    }
}
