import SwiftUI
import MessageUI

struct MailView: UIViewControllerRepresentable {
    @Binding var isShowing: Bool
    @Binding var result: Result<MFMailComposeResult, Error>?

    func makeUIViewController(context: UIViewControllerRepresentableContext<MailView>) -> MFMailComposeViewController {
        let mailController = MFMailComposeViewController()
        mailController.mailComposeDelegate = context.coordinator

        mailController.setToRecipients(["your_email"])
        mailController.setSubject("ARKit Data")
        mailController.setMessageBody("Here is the ARKit data.", isHTML: false)

        attachCSV(fileName: "ARKitData.csv", to: mailController)
        attachCSV(fileName: "ARKitFeaturePoints.csv", to: mailController)

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
