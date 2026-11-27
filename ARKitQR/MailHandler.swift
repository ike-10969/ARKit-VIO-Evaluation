import SwiftUI
import MessageUI

struct MailView: UIViewControllerRepresentable {
    @Binding var isShowing: Bool
    @Binding var result: Result<MFMailComposeResult, Error>?

    func makeUIViewController(context: UIViewControllerRepresentableContext<MailView>) -> MFMailComposeViewController {
        let mailController = MFMailComposeViewController()
        mailController.mailComposeDelegate = context.coordinator

        mailController.setToRecipients([]) // Choose a recipient in the mail composer.
        mailController.setSubject("ARKit and IMU Data")
        mailController.setMessageBody("Here are the ARKit and IMU data files.", isHTML: false)

        [
            "ARKitData.csv",
            "RawAccelerometer.csv",
            "RawGyroscope.csv",
            "DeviceMotion.csv"
        ].forEach { fileName in
            attachCSV(fileName: fileName, to: mailController)
        }

        return mailController
    }

    func updateUIViewController(
        _ uiViewController: MFMailComposeViewController,
        context: UIViewControllerRepresentableContext<MailView>
    ) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isShowing: $isShowing, result: $result)
    }

    private func attachCSV(
        fileName: String,
        to mailController: MFMailComposeViewController
    ) {
        let csvURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent(fileName)

        if let csvData = try? Data(contentsOf: csvURL) {
            mailController.addAttachmentData(
                csvData,
                mimeType: "text/csv",
                fileName: fileName
            )
        } else {
            print("CSV not found: \(fileName)")
        }
    }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var isShowing: Bool
        @Binding var result: Result<MFMailComposeResult, Error>?

        init(
            isShowing: Binding<Bool>,
            result: Binding<Result<MFMailComposeResult, Error>?>
        ) {
            _isShowing = isShowing
            _result = result
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            defer {
                isShowing = false
            }

            if let error = error {
                self.result = .failure(error)
                return
            }

            self.result = .success(result)
        }
    }
}
