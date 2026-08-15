import AppKit
import Vision

struct OCRResult {
    let text: String
    let qrPayloads: [String]

    var clipboardText: String {
        if !qrPayloads.isEmpty && text.isEmpty {
            return qrPayloads.joined(separator: "\n")
        }
        if !qrPayloads.isEmpty {
            return (qrPayloads + [text]).joined(separator: "\n")
        }
        return text
    }
}

final class OCRService {
    static let shared = OCRService()

    func recognize(_ image: CGImage) async -> OCRResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.recognizeSync(image)
                continuation.resume(returning: result)
            }
        }
    }

    private static func recognizeSync(_ image: CGImage) -> OCRResult {
        var lines: [String] = []
        var qrPayloads: [String] = []

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        let langs = Settings.shared.ocrLanguage.visionLanguages
        if !langs.isEmpty {
            textRequest.recognitionLanguages = langs
        } else {
            textRequest.automaticallyDetectsLanguage = true
        }

        let qrRequest = VNDetectBarcodesRequest()
        qrRequest.symbologies = [.qr, .aztec, .dataMatrix, .code128, .ean13]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([textRequest, qrRequest])

        if let observations = textRequest.results {
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
        }
        if let barcodes = qrRequest.results {
            for code in barcodes {
                if let payload = code.payloadStringValue, !payload.isEmpty {
                    qrPayloads.append(payload)
                }
            }
        }

        let joiner = Settings.shared.ocrRemoveLineBreaks ? " " : "\n"
        return OCRResult(text: lines.joined(separator: joiner), qrPayloads: qrPayloads)
    }

    /// Full instant-OCR flow: select area → recognize → clipboard + toast.
    @MainActor
    func instantOCRFlow() {
        SelectionOverlay.begin(purpose: .instantOCRRegion) { result in
            guard case let .area(_, frozen, rect) = result,
                  let cropped = frozen.cropping(toViewRect: rect) else { return }
            Task {
                let ocr = await self.recognize(cropped.cgImage)
                let clip = ocr.clipboardText
                await MainActor.run {
                    if clip.isEmpty {
                        ToastHUD.show("No text or QR found", symbol: "text.magnifyingglass")
                    } else {
                        SaveService.copyText(clip)
                        ToastHUD.show("Text copied (\(clip.count) chars)", symbol: "text.viewfinder")
                        // Lark-style result panel: edit, pick a language, translate
                        TextResultWindow.show(text: clip)
                    }
                }
            }
        }
    }
}
