//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalServiceKit

@objc
public class PrivateStoryNameSettingsViewController: OWSTableViewController2 {

    let thread: TSPrivateStoryThread
    let completionHandler: () -> Void

    required init(thread: TSPrivateStoryThread, completionHandler: @escaping () -> Void) {
        self.thread = thread
        self.completionHandler = completionHandler

        super.init()

        self.shouldAvoidKeyboard = true
    }

    // MARK: - View Lifecycle

    @objc
    public override func viewDidLoad() {
        super.viewDidLoad()

        title = thread.name

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(didTapCancel)
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(didTapSave)
        )

        updateTableContents()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        nameTextField.becomeFirstResponder()
    }

    // MARK: -

    private lazy var nameTextField: UITextField = {
        let textField = UITextField()

        textField.text = thread.name
        textField.font = .ows_dynamicTypeBody
        textField.backgroundColor = .clear
        textField.placeholder = OWSLocalizedString(
            "NEW_PRIVATE_STORY_NAME_PLACEHOLDER",
            comment: "Placeholder text for a new private story name"
        )
        textField.returnKeyType = .done
        textField.delegate = self

        return textField
    }()
    private lazy var iconImageView: UIImageView = {
        let imageView = UIImageView()

        imageView.contentMode = .center
        imageView.layer.cornerRadius = 32
        imageView.clipsToBounds = true
        imageView.autoSetDimensions(to: CGSize(square: 64))

        return imageView
    }()

    public override func applyTheme() {
        super.applyTheme()

        nameTextField.textColor = Theme.primaryTextColor

        iconImageView.setThemeIcon(.privateStory40, tintColor: Theme.primaryIconColor)
        iconImageView.backgroundColor = Theme.isDarkThemeEnabled ? .ows_gray65 : .ows_gray02
    }

    private func updateTableContents() {
        let contents = OWSTableContents()

        let nameAndAvatarSection = OWSTableSection()
        nameAndAvatarSection.add(.init(
            customCellBlock: { [weak self] in
                let cell = OWSTableItem.newCell()
                cell.selectionStyle = .none
                guard let self = self else { return cell }

                self.iconImageView.setContentHuggingVerticalHigh()
                self.nameTextField.setContentHuggingHorizontalLow()
                let firstSection = UIStackView(arrangedSubviews: [
                    self.iconImageView,
                    self.nameTextField
                ])
                firstSection.axis = .horizontal
                firstSection.alignment = .center
                firstSection.spacing = ContactCellView.avatarTextHSpacing

                cell.contentView.addSubview(firstSection)
                firstSection.autoPinEdgesToSuperviewMargins()

                return cell
            },
            actionBlock: {}
        ))
        contents.addSection(nameAndAvatarSection)

        self.contents = contents
    }

    // MARK: - Actions

    @objc
    func didTapCancel() {
        AssertIsOnMainThread()

        if nameTextField.text?.filterForDisplay != thread.name {
            OWSActionSheets.showPendingChangesActionSheet {
                self.dismiss(animated: true)
            }
        } else {
            dismiss(animated: true)
        }
    }

    @objc
    func didTapSave() {
        AssertIsOnMainThread()

        guard let name = nameTextField.text?.nilIfEmpty?.filterForDisplay else {
            return showMissingNameAlert()
        }
        databaseStorage.asyncWrite { transaction in
            self.thread.updateWithName(name, updateStorageService: true, transaction: transaction)
        } completion: { [weak self] in
            guard let self = self else { return }
            self.dismiss(animated: true)
        }
    }

    public override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag, completion: completion)
        completionHandler()
    }

    public func showMissingNameAlert() {
        AssertIsOnMainThread()

        OWSActionSheets.showActionSheet(
            title: OWSLocalizedString(
                "NEW_PRIVATE_STORY_MISSING_NAME_ALERT_TITLE",
                comment: "Title for error alert indicating that a story name is required."
            ),
            message: OWSLocalizedString(
                "NEW_PRIVATE_STORY_MISSING_NAME_ALERT_MESSAGE",
                comment: "Message for error alert indicating that a story name is required."
            )
        )
    }
}

extension PrivateStoryNameSettingsViewController: UITextFieldDelegate {
    public func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string == "\n" {
            didTapSave()
            return false
        } else {
            return true
        }
    }
}