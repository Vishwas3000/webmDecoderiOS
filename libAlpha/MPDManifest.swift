import Foundation

// MARK: - DASH MPD Manifest Model

/// Parsed DASH MPD manifest — extracts segment URLs for VP9+alpha WebM streams.
struct MPDManifest {
    let mediaPresentationDuration: TimeInterval?
    let baseURL: URL
    let periods: [MPDPeriod]
}

struct MPDPeriod {
    let adaptationSets: [MPDAdaptationSet]
}

struct MPDAdaptationSet {
    let mimeType: String              // "video/webm" or "audio/webm"
    let contentType: String           // "video" or "audio" (fallback for mimeType)
    let codecs: String?               // "vp9" or "opus"
    let representations: [MPDRepresentation]

    /// Check if this is a video adaptation set.
    var isVideo: Bool {
        mimeType.contains("video") || contentType.contains("video")
    }
    /// Check if this is an audio adaptation set.
    var isAudio: Bool {
        mimeType.contains("audio") || contentType.contains("audio")
    }
}

struct MPDRepresentation {
    let id: String
    let mimeType: String?             // may be on Representation instead of AdaptationSet
    let bandwidth: Int                // bits/sec for ABR
    let width: Int?
    let height: Int?
    let segmentBase: MPDSegmentBase?
    let segmentTemplate: MPDSegmentTemplate?
}

struct MPDSegmentBase {
    let indexRange: String?
    let initializationRange: String?
}

struct MPDSegmentTemplate {
    let initialization: String?       // e.g. "init-$RepresentationID$.webm"
    let media: String?                // e.g. "chunk-$RepresentationID$-$Number$.webm"
    let startNumber: Int
    let timescale: Int
    let duration: Int?                // segment duration in timescale units
    let timeline: [SegmentTimelineEntry]?
}

struct SegmentTimelineEntry {
    let t: Int?       // start time (optional)
    let d: Int        // duration
    let r: Int        // repeat count (0 = no repeat, -1 = repeat until end)
}

// MARK: - URL Generation

extension MPDManifest {

    /// Find the video AdaptationSet.
    var videoAdaptationSet: MPDAdaptationSet? {
        for period in periods {
            if let set = period.adaptationSets.first(where: { $0.isVideo }) {
                return set
            }
        }
        return nil
    }

    /// Find the audio AdaptationSet.
    var audioAdaptationSet: MPDAdaptationSet? {
        for period in periods {
            if let set = period.adaptationSets.first(where: { $0.isAudio }) {
                return set
            }
        }
        return nil
    }
}

extension MPDRepresentation {

    /// Resolve the initialization segment URL.
    func initSegmentURL(baseURL: URL) -> URL? {
        guard let tmpl = segmentTemplate, let initStr = tmpl.initialization else { return nil }
        let resolved = initStr.replacingOccurrences(of: "$RepresentationID$", with: id)
        return URL(string: resolved, relativeTo: baseURL)
    }

    /// Generate all media segment URLs in order.
    func mediaSegmentURLs(baseURL: URL, totalDuration: TimeInterval?) -> [URL] {
        guard let tmpl = segmentTemplate, let mediaStr = tmpl.media else { return [] }

        var urls: [URL] = []

        if let timeline = tmpl.timeline, !timeline.isEmpty {
            // Explicit SegmentTimeline
            var number = tmpl.startNumber
            for entry in timeline {
                let repeatCount = max(0, entry.r) + 1
                for _ in 0 ..< repeatCount {
                    let resolved = Self.resolveTemplate(mediaStr, repID: id, number: number)
                    if let url = URL(string: resolved, relativeTo: baseURL) {
                        urls.append(url)
                    }
                    number += 1
                }
            }
        } else if let segDuration = tmpl.duration, segDuration > 0, let total = totalDuration {
            // SegmentTemplate with fixed duration
            let segDurationSec = Double(segDuration) / Double(tmpl.timescale)
            let segmentCount = Int(ceil(total / segDurationSec))
            for i in 0 ..< segmentCount {
                let number = tmpl.startNumber + i
                let resolved = Self.resolveTemplate(mediaStr, repID: id, number: number)
                if let url = URL(string: resolved, relativeTo: baseURL) {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    /// Resolve DASH template variables including printf-style format specifiers.
    /// Handles: `$RepresentationID$`, `$Number$`, `$Number%05d$`, etc.
    private static func resolveTemplate(_ template: String, repID: String, number: Int) -> String {
        var result = template.replacingOccurrences(of: "$RepresentationID$", with: repID)

        // Handle $Number%XXd$ (e.g. $Number%05d$) — printf-style zero-padded number
        if let range = result.range(of: #"\$Number%(\d+)d\$"#, options: .regularExpression) {
            let match = String(result[range])
            // Extract the width number (e.g. "05" from "$Number%05d$")
            let digits = match.replacingOccurrences(of: "$Number%", with: "")
                             .replacingOccurrences(of: "d$", with: "")
            let width = Int(digits) ?? 0
            let formatted = String(format: "%0\(width)d", number)
            result = result.replacingCharacters(in: range, with: formatted)
        } else {
            // Simple $Number$ replacement
            result = result.replacingOccurrences(of: "$Number$", with: "\(number)")
        }

        return result
    }
}

// MARK: - XML Parser

extension MPDManifest {

    /// Parse an MPD XML document.
    /// `baseURL` is the URL of the MPD file itself (used to resolve relative segment URLs).
    init?(xmlData: Data, baseURL: URL) {
        let delegate = MPDXMLParserDelegate()
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        self.baseURL = baseURL.deletingLastPathComponent()  // directory of .mpd
        self.mediaPresentationDuration = delegate.mediaPresentationDuration
        self.periods = delegate.periods
    }
}

// MARK: - XMLParser Delegate

private final class MPDXMLParserDelegate: NSObject, XMLParserDelegate {
    var mediaPresentationDuration: TimeInterval?
    var periods: [MPDPeriod] = []

    // Parser stack
    private var currentPeriod: PeriodBuilder?
    private var currentAdaptationSet: AdaptationSetBuilder?
    private var currentRepresentation: RepresentationBuilder?
    private var currentSegmentTemplate: SegmentTemplateBuilder?
    private var currentTimeline: [SegmentTimelineEntry] = []
    private var inSegmentTimeline = false
    private var currentText = ""
    private var currentBaseURL: String?

    // MARK: Builders (mutable during parse)

    private class PeriodBuilder {
        var adaptationSets: [MPDAdaptationSet] = []
    }

    private class AdaptationSetBuilder {
        var mimeType = ""
        var contentType = ""
        var codecs: String?
        var representations: [MPDRepresentation] = []
        // Inherited SegmentTemplate (AdaptationSet-level)
        var segmentTemplate: SegmentTemplateBuilder?
    }

    private class RepresentationBuilder {
        var id = ""
        var mimeType: String?
        var bandwidth = 0
        var width: Int?
        var height: Int?
        var segmentBase: MPDSegmentBase?
        var segmentTemplate: SegmentTemplateBuilder?
    }

    private class SegmentTemplateBuilder {
        var initialization: String?
        var media: String?
        var startNumber = 1
        var timescale = 1
        var duration: Int?
        var timeline: [SegmentTimelineEntry]?

        func build() -> MPDSegmentTemplate {
            MPDSegmentTemplate(
                initialization: initialization,
                media: media,
                startNumber: startNumber,
                timescale: timescale,
                duration: duration,
                timeline: timeline
            )
        }

        func copy() -> SegmentTemplateBuilder {
            let c = SegmentTemplateBuilder()
            c.initialization = initialization
            c.media = media
            c.startNumber = startNumber
            c.timescale = timescale
            c.duration = duration
            c.timeline = timeline
            return c
        }
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        currentText = ""

        switch name {
        case "MPD":
            if let dur = attributes["mediaPresentationDuration"] {
                mediaPresentationDuration = parseISO8601Duration(dur)
            }

        case "Period":
            currentPeriod = PeriodBuilder()

        case "AdaptationSet":
            let builder = AdaptationSetBuilder()
            builder.mimeType = attributes["mimeType"] ?? ""
            builder.contentType = attributes["contentType"] ?? ""
            builder.codecs = attributes["codecs"]
            currentAdaptationSet = builder

        case "Representation":
            let builder = RepresentationBuilder()
            builder.id = attributes["id"] ?? ""
            builder.mimeType = attributes["mimeType"]
            builder.bandwidth = Int(attributes["bandwidth"] ?? "0") ?? 0
            builder.width = Int(attributes["width"] ?? "")
            builder.height = Int(attributes["height"] ?? "")
            currentRepresentation = builder

        case "SegmentTemplate":
            let builder = SegmentTemplateBuilder()
            builder.initialization = attributes["initialization"]
            builder.media = attributes["media"]
            builder.startNumber = Int(attributes["startNumber"] ?? "1") ?? 1
            builder.timescale = Int(attributes["timescale"] ?? "1") ?? 1
            builder.duration = Int(attributes["duration"] ?? "")
            if currentRepresentation != nil {
                currentRepresentation?.segmentTemplate = builder
            } else if currentAdaptationSet != nil {
                currentAdaptationSet?.segmentTemplate = builder
            }
            currentSegmentTemplate = builder

        case "SegmentBase":
            let sb = MPDSegmentBase(
                indexRange: attributes["indexRange"],
                initializationRange: nil
            )
            currentRepresentation?.segmentBase = sb

        case "SegmentTimeline":
            inSegmentTimeline = true
            currentTimeline = []

        case "S":
            if inSegmentTimeline {
                let entry = SegmentTimelineEntry(
                    t: Int(attributes["t"] ?? ""),
                    d: Int(attributes["d"] ?? "0") ?? 0,
                    r: Int(attributes["r"] ?? "0") ?? 0
                )
                currentTimeline.append(entry)
            }

        case "BaseURL":
            break // text will be captured in foundCharacters

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "MPD":
            break

        case "Period":
            if let period = currentPeriod {
                periods.append(MPDPeriod(adaptationSets: period.adaptationSets))
            }
            currentPeriod = nil

        case "AdaptationSet":
            if let set = currentAdaptationSet {
                // Resolve mimeType: prefer AdaptationSet level, fall back to Representation level
                var resolvedMimeType = set.mimeType
                if resolvedMimeType.isEmpty, let firstRep = set.representations.first,
                   let repMime = firstRep.mimeType {
                    resolvedMimeType = repMime
                }
                currentPeriod?.adaptationSets.append(
                    MPDAdaptationSet(
                        mimeType: resolvedMimeType,
                        contentType: set.contentType,
                        codecs: set.codecs,
                        representations: set.representations
                    )
                )
            }
            currentAdaptationSet = nil

        case "Representation":
            if let rep = currentRepresentation {
                // Inherit SegmentTemplate from AdaptationSet if not set on Representation
                let tmpl = rep.segmentTemplate ?? currentAdaptationSet?.segmentTemplate
                let representation = MPDRepresentation(
                    id: rep.id,
                    mimeType: rep.mimeType,
                    bandwidth: rep.bandwidth,
                    width: rep.width,
                    height: rep.height,
                    segmentBase: rep.segmentBase,
                    segmentTemplate: tmpl?.build()
                )
                currentAdaptationSet?.representations.append(representation)
            }
            currentRepresentation = nil

        case "SegmentTemplate":
            currentSegmentTemplate = nil

        case "SegmentTimeline":
            inSegmentTimeline = false
            currentSegmentTemplate?.timeline = currentTimeline

        case "BaseURL":
            currentBaseURL = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        default:
            break
        }
    }

    // MARK: ISO 8601 Duration

    /// Parse "PT40S", "PT1M30S", "PT1H2M3.5S" etc.
    private func parseISO8601Duration(_ str: String) -> TimeInterval? {
        var s = str
        guard s.hasPrefix("PT") || s.hasPrefix("P") else { return nil }
        s = String(s.dropFirst(s.hasPrefix("PT") ? 2 : 1))

        var total: TimeInterval = 0
        var numStr = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                numStr.append(ch)
            } else {
                guard let val = Double(numStr) else { numStr = ""; continue }
                switch ch {
                case "H": total += val * 3600
                case "M": total += val * 60
                case "S": total += val
                default: break
                }
                numStr = ""
            }
        }
        return total
    }
}
