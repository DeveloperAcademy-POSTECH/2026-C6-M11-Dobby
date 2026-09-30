import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private var snapshot: KeyboardProductSnapshot?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        reloadProduct()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProduct()
    }

    private func buildInterface() {
        view.backgroundColor = .systemBackground

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2

        let nextKeyboardButton = makeButton(title: "🌐", action: #selector(nextKeyboard))
        nextKeyboardButton.accessibilityLabel = "다른 키보드"

        let header = UIStackView(arrangedSubviews: [statusLabel, nextKeyboardButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        let rows: [[(String, Selector)]] = [
            [("상품명", #selector(insertProductName)), ("설명", #selector(insertDescription)), ("브랜드", #selector(insertBrand))],
            [("가격", #selector(insertPrice)), ("총장", #selector(insertLength)), ("허리", #selector(insertWaist)), ("허벅지", #selector(insertThigh))],
            [("실측 전체", #selector(insertMeasurements))]
        ]

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(header)

        for rowItems in rows {
            let row = UIStackView(arrangedSubviews: rowItems.map { makeButton(title: $0.0, action: $0.1) })
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            root.addArrangedSubview(row)
        }

        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = UIColor.secondarySystemBackground
        configuration.baseForegroundColor = UIColor.label
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func reloadProduct() {
        snapshot = KeyboardProductStore.load()
        statusLabel.text = snapshot == nil
            ? "Dobby에서 내보내기를 먼저 열어주세요"
            : "Dobby 상품 정보 입력"
    }

    private func insert(_ value: String?) {
        guard let value, !value.isEmpty else {
            statusLabel.text = "입력할 정보가 없어요"
            return
        }
        textDocumentProxy.insertText(value)
        statusLabel.text = "입력했어요"
    }

    @objc private func nextKeyboard() { advanceToNextInputMode() }
    @objc private func insertProductName() { insert(snapshot?.productName) }
    @objc private func insertDescription() { insert(snapshot?.description) }
    @objc private func insertBrand() { insert(snapshot?.brand) }
    @objc private func insertPrice() { insert(snapshot?.price) }
    @objc private func insertLength() { insert(snapshot?.length) }
    @objc private func insertWaist() { insert(snapshot?.waist) }
    @objc private func insertThigh() { insert(snapshot?.thigh) }
    @objc private func insertMeasurements() { insert(snapshot?.measurements) }
}

