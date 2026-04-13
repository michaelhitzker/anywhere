import Darwin
import Foundation

let phoneBonjourServiceType = "_anywhere-bridge._tcp."
let phoneBonjourDomain = "local."

struct PhoneDiscoveredCompanion: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int

    var urlString: String {
        "http://\(host):\(port)"
    }
}

@MainActor
final class PhoneBonjourDiscovery: NSObject {
    var onUpdate: (([PhoneDiscoveredCompanion]) -> Void)?
    var onStateChange: ((Bool, String?) -> Void)?
    var onPreferredCompanionResolved: ((PhoneDiscoveredCompanion) -> Void)?

    private let browser = NetServiceBrowser()
    private var servicesByIdentifier: [String: NetService] = [:]
    private var companionsByIdentifier: [String: PhoneDiscoveredCompanion] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.stop()
        servicesByIdentifier.removeAll()
        companionsByIdentifier.removeAll()
        onUpdate?([])
        onStateChange?(true, nil)
        browser.searchForServices(ofType: phoneBonjourServiceType, inDomain: phoneBonjourDomain)
    }

    func stop() {
        browser.stop()
        onStateChange?(false, nil)
    }

    private func identifier(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func publishCompanions() {
        let companions = companionsByIdentifier.values.sorted {
            if $0.name == $1.name {
                return $0.urlString < $1.urlString
            }

            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        onUpdate?(companions)
    }

    private func preferredHost(for service: NetService) -> String? {
        if let addressHost = service.addresses?.compactMap(Self.ipv4Host).first {
            return addressHost
        }

        return service.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func ipv4Host(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer -> String? in
            guard let baseAddress = rawBuffer.baseAddress else {
                return nil
            }

            let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
            guard sockaddrPointer.pointee.sa_family == sa_family_t(AF_INET) else {
                return nil
            }

            var address = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }

            return String(cString: buffer)
        }
    }
}

extension PhoneBonjourDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        onStateChange?(true, nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        onStateChange?(false, "Couldn't search the local network (\(code)).")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        onStateChange?(false, nil)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let serviceIdentifier = identifier(for: service)
        servicesByIdentifier[serviceIdentifier] = service
        service.delegate = self
        service.resolve(withTimeout: 5)

        if !moreComing {
            publishCompanions()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let serviceIdentifier = identifier(for: service)
        servicesByIdentifier.removeValue(forKey: serviceIdentifier)
        companionsByIdentifier.removeValue(forKey: serviceIdentifier)

        if !moreComing {
            publishCompanions()
        }
    }
}

extension PhoneBonjourDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceIdentifier = identifier(for: sender)
        guard let hostName = preferredHost(for: sender),
              !hostName.isEmpty else {
            return
        }

        let companion = PhoneDiscoveredCompanion(
            id: "\(serviceIdentifier)|\(hostName)|\(sender.port)",
            name: sender.name,
            host: hostName,
            port: sender.port
        )

        companionsByIdentifier[serviceIdentifier] = companion
        publishCompanions()
        onPreferredCompanionResolved?(companion)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        onStateChange?(true, "Nearby Mac found, but its address couldn't be resolved (\(code)).")
    }
}
