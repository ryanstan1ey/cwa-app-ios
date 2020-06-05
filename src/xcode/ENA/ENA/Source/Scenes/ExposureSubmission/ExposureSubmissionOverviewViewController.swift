// Corona-Warn-App
//
// SAP SE and all other contributors
// copyright owners license this file to you under the Apache
// License, Version 2.0 (the "License"); you may not use this
// file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import AVFoundation
import Foundation
import UIKit


class ExposureSubmissionOverviewViewController: DynamicTableViewController, SpinnerInjectable {

	// MARK: - Attributes.

	@IBAction func unwindToExposureSubmissionIntro(_: UIStoryboardSegue) {}
	private var service: ExposureSubmissionService?
	var spinner: UIActivityIndicatorView?

	// MARK: - Initializers.

	required init?(coder aDecoder: NSCoder) {
		super.init(coder: aDecoder)
	}

	// MARK: - View lifecycle methods.

	override func viewDidLoad() {
		super.viewDidLoad()
		dynamicTableViewModel = dynamicTableData()
		setupView()

		// Grab ExposureSubmissionService from the navigation controller
		// (which is the entry point for the storyboard, and in which
		// this controller is embedded.)
		if let navC = navigationController as? ExposureSubmissionNavigationController {
			service = navC.getExposureSubmissionService()
		}
	}

	private func setupView() {
		tableView.register(
			UINib(
				nibName: String(describing: ExposureSubmissionTestResultHeaderView.self),
				bundle: nil
			),
			forHeaderFooterViewReuseIdentifier: "test"
		)
		tableView.register(DynamicTableViewImageCardCell.self, forCellReuseIdentifier: CustomCellReuseIdentifiers.imageCard.rawValue)
		title = AppStrings.ExposureSubmissionDispatch.title
	}

	// MARK: - Segue handling.

	override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
		let destination = segue.destination
		switch Segue(segue) {
		case .tanInput:
			let vc = destination as? ExposureSubmissionTanInputViewController
			vc?.initialTan = sender as? String
			vc?.exposureSubmissionService = service
		case .qrScanner:
			let vc = destination as? ExposureSubmissionQRScannerNavigationController
			vc?.scannerViewController?.delegate = self
			vc?.exposureSubmissionService = service
		case .labResult:
			let vc = destination as? ExposureSubmissionTestResultViewController
			vc?.exposureSubmissionService = service
			vc?.testResult = sender as? TestResult
		default:
			break
		}
	}

	// MARK: - Helpers.

	private func fetchResult() {
		startSpinner()
		service?.getTestResult { result in
			self.stopSpinner()
			switch result {
			case let .failure(error):
				logError(message: "An error occured during result fetching: \(error)", level: .error)
				let alert = ExposureSubmissionViewUtils.setupErrorAlert(error)
				self.present(alert, animated: true, completion: nil)
			case let .success(testResult):
				self.performSegue(withIdentifier: Segue.labResult, sender: testResult)
			}
		}
	}

	/// Shows the data privacy disclaimer and only lets the
	/// user scan a QR code after accepting.
	func showDisclaimer() {
		let alert = UIAlertController(
			title: AppStrings.ExposureSubmission.dataPrivacyTitle,
			message: AppStrings.ExposureSubmission.dataPrivacyDisclaimer,
			preferredStyle: .alert
		)
		let acceptAction = UIAlertAction(title: AppStrings.ExposureSubmission.dataPrivacyAcceptTitle, style: .default, handler: { _ in
											self.service?.acceptPairing()
											self.performSegue(
												withIdentifier: Segue.qrScanner,
												sender: self
											)
		})
		alert.addAction(acceptAction)

		alert.addAction(.init(title: AppStrings.ExposureSubmission.dataPrivacyDontAcceptTitle,
							  style: .cancel,
							  handler: { _ in
								alert.dismiss(animated: true, completion: nil) }
			))
		alert.preferredAction = acceptAction
		present(alert, animated: true, completion: nil)
	}
}

// MARK: - Segue extension.

extension ExposureSubmissionOverviewViewController {
	enum Segue: String, SegueIdentifiers {
		case tanInput = "tanInputSegue"
		case qrScanner = "qrScannerSegue"
		case testDetails = "testDetailsSegue"
		case hotline = "hotlineSegue"
		case labResult = "labResultSegue"
	}
}

// MARK: - ExposureSubmissionQRScannerDelegate methods.

extension ExposureSubmissionOverviewViewController: ExposureSubmissionQRScannerDelegate {
	func qrScanner(_ viewController: ExposureSubmissionQRScannerViewController, error: QRScannerError) {
		switch error {
		case .cameraPermissionDenied:
			let alert = ExposureSubmissionViewUtils.setupErrorAlert(error) {
				self.dismissQRCodeScannerView(viewController, completion: nil)
			}
			viewController.present(alert, animated: true, completion: nil)
		default:
			logError(message: "QRScannerError.other occured.", level: .error)
		}
	}

	func qrScanner(_ vc: ExposureSubmissionQRScannerViewController, didScan code: String) {
		guard let guid = sanitizeAndExtractGuid(code) else {
			vc.delegate = nil
			let alert = ExposureSubmissionViewUtils.setupAlert(
				title: AppStrings.ExposureSubmissionQRScanner.alertCodeNotFoundTitle,
				message: AppStrings.ExposureSubmissionQRScanner.alertCodeNotFoundText,
				okTitle: AppStrings.Common.alertActionCancel,
				retry: true,
				action: {
					self.dismissQRCodeScannerView(vc, completion: nil)
				},
				retryActionHandler: { vc.delegate = self }
			)
			vc.present(alert, animated: true, completion: nil)
			return
		}

		// Found QR Code, deactivate scanning.
		dismissQRCodeScannerView(vc, completion: {
			self.startSpinner()
			self.getRegistrationToken(forKey: .guid(guid))
		})
	}

	private func getRegistrationToken(forKey: DeviceRegistrationKey) {
		service?.getRegistrationToken(forKey: forKey, completion: { result in
			self.stopSpinner()
			switch result {
			case let .failure(error):
				logError(message: "Error while getting registration token: \(error)", level: .error)
				let alert = ExposureSubmissionViewUtils.setupErrorAlert(error, retry: true, retryActionHandler: {
					self.startSpinner()
					self.getRegistrationToken(forKey: forKey)
				})
				self.present(alert, animated: true, completion: nil)

			case let .success(token):
				appLogger.log(
					message: "Received registration token: \(token)",
					file: #file,
					line: #line,
					function: #function
				)
				self.fetchResult()
			}
        })
	}

	/// Sanitize the input string and assert that:
	/// - length is smaller than 128 characters
	/// - starts with https://
	/// - contains only alphanumeric characters
	/// - is not empty
	private func sanitizeAndExtractGuid(_ input: String) -> String? {
		guard input.count <= 150 else { return nil }
		guard let regex = try? NSRegularExpression(pattern: "^.*\\?(?<GUID>[A-Z,a-z,0-9,-]*)") else { return nil }
		guard let match = regex.firstMatch(in: input, options: [], range: NSRange(location: 0, length: input.utf8.count)) else { return nil }
		let nsRange = match.range(withName: "GUID")
		guard let range = Range(nsRange, in: input) else { return nil }
		let candidate = String(input[range])
		guard !candidate.isEmpty, candidate.count <= 80 else { return nil }
		return candidate
	}

	private func dismissQRCodeScannerView(_ vc: ExposureSubmissionQRScannerViewController, completion: (() -> Void)?) {
		vc.delegate = nil
		vc.dismiss(animated: true, completion: completion)
	}
}

// MARK: Data extension for DynamicTableView.

private extension ExposureSubmissionOverviewViewController {
	func dynamicTableData() -> DynamicTableViewModel {
		var data = DynamicTableViewModel([])

		let header = DynamicHeader.blank

		data.add(
			.section(
				header: header,
				separators: false,
				cells: [
					.body(text: AppStrings.ExposureSubmissionDispatch.description)
				]
			)
		)

		data.add(DynamicSection.section(cells: [
			.identifier(
				CustomCellReuseIdentifiers.imageCard,
				action: .execute(block: { _ in
					self.showDisclaimer()
				}),
				configure: { _, cell, _ in
					guard let cell = cell as? DynamicTableViewImageCardCell else { return }
					cell.configure(
						title: AppStrings.ExposureSubmissionDispatch.qrCodeButtonTitle,
						image: UIImage(named: "Illu_Submission_QRCode"),
						body: AppStrings.ExposureSubmissionDispatch.qrCodeButtonDescription
					)
				}
			),
			.identifier(
				CustomCellReuseIdentifiers.imageCard,
				action: .perform(segue: Segue.tanInput),
				configure: { _, cell, _ in
					guard let cell = cell as? DynamicTableViewImageCardCell else { return }
					cell.configure(
						title: AppStrings.ExposureSubmissionDispatch.tanButtonTitle,
						image: UIImage(named: "Illu_Submission_TAN"),
						body: AppStrings.ExposureSubmissionDispatch.tanButtonDescription
					)
				}
			),
			.identifier(
				CustomCellReuseIdentifiers.imageCard,
				action: .perform(segue: Segue.hotline),
				configure: { _, cell, _ in
					guard let cell = cell as? DynamicTableViewImageCardCell else { return }
					cell.configure(
						title: AppStrings.ExposureSubmissionDispatch.hotlineButtonTitle,
						image: UIImage(named: "Illu_Submission_Anruf"),
						body: AppStrings.ExposureSubmissionDispatch.hotlineButtonDescription,
						attributedStrings: self.getAttributedStrings()
					)
				}
			)
		]))

		return data
	}

	/// Gets the attributed string that makes the "Positive" word bold.
	private func getAttributedStrings() -> [NSAttributedString] {
		let font: UIFont = .preferredFont(forTextStyle: .body)
		let boldFont: UIFont = UIFont.boldSystemFont(ofSize: font.pointSize)
		let attr: [NSAttributedString.Key: Any] = [.font: boldFont]
		let word = NSAttributedString(string: AppStrings.ExposureSubmissionDispatch.positiveWord, attributes: attr)
		return [word]
	}

	private func transitionToQRScanner(_: UIViewController) {
		// Make sure we are allowed to use the camera.
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized, .notDetermined:
			performSegue(withIdentifier: Segue.qrScanner, sender: self)
		case .denied:
			let alert = ExposureSubmissionViewUtils.setupAlert(
				message: AppStrings.ExposureSubmissionQRScanner.cameraPermissionDenied
			)
			present(alert, animated: true, completion: nil)
		case .restricted:
			let alert = ExposureSubmissionViewUtils.setupAlert(
				message: AppStrings.ExposureSubmissionQRScanner.cameraPermissionRestricted
			)
			present(alert, animated: true, completion: nil)
        // swiftlint:disable:next switch_case_alignment
        @unknown default:
			log(message: "Unhandled  AVCaptureDevice state.")
		}
	}
}

// MARK: - Cell reuse identifiers.

extension ExposureSubmissionOverviewViewController {
	enum CustomCellReuseIdentifiers: String, TableViewCellReuseIdentifiers {
		case imageCard = "imageCardCell"
	}
}
