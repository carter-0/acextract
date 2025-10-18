//
//  Operation.swift
//
//  The MIT License (MIT)
//
//  Copyright (c) 2016 Bartosz Janda
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation
#if os(macOS)
import CoreServices
#else
import MobileCoreServices
#endif

// MARK: - Protocols
protocol Operation {
    func read(catalog: AssetsCatalog) throws
}

struct CompoundOperation: Operation {
    let operations: [Operation]

    func read(catalog: AssetsCatalog) throws {
        for operation in operations {
            try operation.read(catalog: catalog)
        }
    }
}

// MARK: - Helpers
let escapeSeq = "\u{1b}"
let boldSeq = "[1m"
let resetSeq = "[0m"
let redColorSeq = "[31m"

// MARK: - ExtractOperation
enum ExtractOperationError: Error {
    case outputPathIsNotDirectory
    case renditionMissingData
    case cannotSaveImage
    case cannotCreatePDFDocument
    case cannotSaveData
    case unsupportedFormat
}

enum ImageFormat {
    case png
    case pdf
    case heic
    case gif
    case tiff
    case jpeg
    case bmp

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .pdf: return "pdf"
        case .heic: return "heic"
        case .gif: return "gif"
        case .tiff: return "tiff"
        case .jpeg: return "jpeg"
        case .bmp: return "bmp"
        }
    }

    var utType: CFString {
        switch self {
        case .png: return kUTTypePNG
        case .pdf: return kUTTypePDF
        case .heic: return "public.heic" as CFString
        case .gif: return kUTTypeGIF
        case .tiff: return kUTTypeTIFF
        case .jpeg: return kUTTypeJPEG
        case .bmp: return kUTTypeBMP
        }
    }
}

struct ExtractOperation: Operation {

    // MARK: Properties
    let outputPath: String

    // MARK: Initialization
    init(path: String) {
        outputPath = (path as NSString).expandingTildeInPath
    }

    // MARK: Methods
    func read(catalog: AssetsCatalog) throws {
        // Create output folder if needed
        try checkAndCreateFolder()
        // For every image set and every named image.
        for imageSet in catalog.imageSets {
            for namedImage in imageSet.namedImages {
                // Save image to file.
                extractNamedImage(namedImage: namedImage)
            }
        }
    }

    // MARK: Private methods
    /**
     Checks if output folder exists nad create it if needed.

     - throws: Throws if output path is pointing to file, or it si not possible to create folder.
     */
    private func checkAndCreateFolder() throws {
        // Check if directory exists at given path and it is directory.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDirectory) && !(isDirectory.boolValue) {
            throw ExtractOperationError.outputPathIsNotDirectory
        } else {
            try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true, attributes: nil)
        }
    }

    /**
     Extract image to file.

     - parameter namedImage: Named image to save.
     */
    private func extractNamedImage(namedImage: CUINamedImage) {
        let filePath = (outputPath as NSString).appendingPathComponent(namedImage.acImageName)
        print("Extracting: \(namedImage.acImageName)", terminator: "")
        do {
            try namedImage.acSaveAtPath(filePath: filePath)
            print(" \(escapeSeq+boldSeq)OK\(escapeSeq+resetSeq)")
        } catch {
            print(" \(escapeSeq+boldSeq)\(escapeSeq+redColorSeq)FAILED\(escapeSeq+resetSeq) \(error)")
        }
    }
}

private extension CUINamedImage {
    /**
     Detect the image format from the rendition's UTI type.

     - returns: The detected ImageFormat, or nil if format is not supported.
     */
    func acDetectFormat() -> ImageFormat? {
        // Check for PDF first
        if self._rendition().pdfDocument() != nil {
            return .pdf
        }

        if let utiType = self._rendition().utiType() {
            let utiString = utiType.lowercased()

            if utiString.contains("heic") || utiString.contains("heif") {
                return .heic
            }
            if utiString.contains("gif") {
                return .gif
            }
            if utiString.contains("tiff") || utiString.contains("tif") {
                return .tiff
            }
            if utiString.contains("jpeg") || utiString.contains("jpg") {
                return .jpeg
            }
            if utiString.contains("bmp") {
                return .bmp
            }
        }

        if self._rendition().unslicedImage() != nil {
            return .png
        }

        return nil
    }

    /**
     Extract given image in its appropriate format.

     - parameter filePath: Path where file should be saved.

     - throws: Throws if there is no image data or format is not supported.
     */
    func acSaveAtPath(filePath: String) throws {
        guard let format = acDetectFormat() else {
            throw ExtractOperationError.renditionMissingData
        }

        switch format {
        case .pdf:
            try self.acSavePDF(filePath: filePath)
        case .png, .heic, .gif, .tiff, .jpeg, .bmp:
            try self.acSaveImage(filePath: filePath, format: format)
        }
    }

    /**
     Save image in the specified format.

     - parameter filePath: Path where file should be saved.
     - parameter format: The image format to use.

     - throws: Throws if cannot save image.
     */
    func acSaveImage(filePath: String, format: ImageFormat) throws {
        let filePathURL = NSURL(fileURLWithPath: filePath)
        guard let cgImage = self._rendition().unslicedImage()?.takeUnretainedValue() else {
            throw ExtractOperationError.cannotSaveImage
        }
        guard let cgDestination = CGImageDestinationCreateWithURL(filePathURL, format.utType, 1, nil) else {
            throw ExtractOperationError.cannotSaveImage
        }

        CGImageDestinationAddImage(cgDestination, cgImage, nil)

        if !CGImageDestinationFinalize(cgDestination) {
            throw ExtractOperationError.cannotSaveImage
        }
    }

    func acSavePDF(filePath: String) throws {
        // Based on:
        // http://stackoverflow.com/questions/3780745/saving-a-pdf-document-to-disk-using-quartz

        guard let cgPDFDocument = self._rendition().pdfDocument()?.takeUnretainedValue() else {
            throw ExtractOperationError.cannotCreatePDFDocument
        }
        // Create the pdf context
        let cgPage = CGPDFDocument.page(cgPDFDocument) as! CGPDFPage // swiftlint:disable:this force_cast
        var cgPageRect = cgPage.getBoxRect(.mediaBox)
        let mutableData = NSMutableData()

        let cgDataConsumer = CGDataConsumer(data: mutableData)
        let cgPDFContext = CGContext(consumer: cgDataConsumer!, mediaBox: &cgPageRect, nil)
        defer {
            cgPDFContext!.closePDF()
        }

        if cgPDFDocument.numberOfPages > 0 {
            cgPDFContext!.beginPDFPage(nil)
            cgPDFContext!.drawPDFPage(cgPage)
            cgPDFContext!.endPDFPage()
        } else {
            throw ExtractOperationError.cannotCreatePDFDocument
        }

        if !mutableData.write(toFile: filePath, atomically: true) {
            throw ExtractOperationError.cannotCreatePDFDocument
        }
    }
}
