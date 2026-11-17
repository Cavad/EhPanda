public import AppModels
import Foundation
public import Kanna

extension Parser {
    public static func parseSkipServerIdentifier(doc: any HTMLDocument) throws -> String {
        guard let text = doc.at_xpath("//div [@id='i6']")?.at_xpath("//a [@id='loadfail']")?["onclick"],
              let rangeA = text.range(of: "nl('"), let rangeB = text.range(of: "')")
        else { throw AppError.parseFailed }
        return .init(text[rangeA.upperBound..<rangeB.lowerBound])
    }

    public static func parseAPIKey(doc: any HTMLDocument) throws -> String {
        var tmpKey: String?

        for link in doc.xpath("//script [@type='text/javascript']") {
            guard let script = link.text, script.contains("apikey"),
                  let rangeA = script.range(of: ";\nvar apikey = \""),
                  let rangeB = script.range(of: "\";\nvar average_rating")
            else { continue }

            tmpKey = String(script[rangeA.upperBound..<rangeB.lowerBound])
        }

        guard let apikey = tmpKey
        else { throw AppError.parseFailed }

        return apikey
    }

    /// Parses the gallery-list pager.
    public static func parsePageNum(doc: any HTMLDocument) -> PageNumber {
        guard let link = doc.at_xpath("//table [@class='ptt']"),
              let currentStr = link.at_xpath("//td [@class='ptds']")?.text
        else {
            guard let navigation = doc.at_xpath("//div [@class='searchnav']") else { return PageNumber() }
            for link in navigation.xpath(".//a") where link.text?.contains("Next") == true {
                let cursor = link["href"]
                    .map(URLComponents.init)??
                    .queryItems?
                    .first(where: { $0.name == "next" })?
                    .value?
                    .split(separator: "-")
                guard let cursor, let gid = cursor.first else { continue }
                return PageNumber(
                    lastItemTimestamp: cursor.last.map(String.init),
                    isNextButtonEnabled: true,
                    nextGalleryID: String(gid)
                )
            }
            return PageNumber()
        }

        let page = currentStr.split(separator: "-").last.flatMap({ Int($0) }) ?? 1
        let current = max(page, 1) - 1
        var maximum = current
        for aLink in link.xpath(".//a") {
            if let num = Int(aLink.text ?? "") {
                maximum = max(maximum, max(num, 1) - 1)
            }
        }
        return PageNumber(current: current, maximum: maximum)
    }
}
