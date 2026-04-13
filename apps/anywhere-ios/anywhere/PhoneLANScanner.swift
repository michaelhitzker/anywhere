import Darwin
import Foundation

struct PhoneLANScanner {
    private struct ProbeHealth: Decodable {
        struct ProviderInfo: Decodable {
            let id: String?
        }

        let ok: Bool
        let service: String?
        let provider: ProviderInfo?
    }

    func scan(port: Int = 4242) async -> PhoneDiscoveredCompanion? {
        guard let prefix = Self.wifiIPv4Prefix() else {
            return nil
        }

        return await withTaskGroup(of: PhoneDiscoveredCompanion?.self) { group in
            for suffix in 1...254 {
                let host = "\(prefix).\(suffix)"
                group.addTask {
                    await probe(host: host, port: port)
                }
            }

            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }

            return nil
        }
    }

    private func probe(host: String, port: Int) async -> PhoneDiscoveredCompanion? {
        guard let url = URL(string: "http://\(host):\(port)/api/health") else {
            return nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.55
        configuration.timeoutIntervalForResource = 0.55
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let health = try JSONDecoder().decode(ProbeHealth.self, from: data)
            guard health.ok,
                  health.service == "anywhere-bridge",
                  health.provider?.id == "t3code" else {
                return nil
            }

            return PhoneDiscoveredCompanion(
                id: "lan-scan|\(host)|\(port)",
                name: "Anywhere Bridge on \(host)",
                host: host,
                port: port
            )
        } catch {
            return nil
        }
    }

    private static func wifiIPv4Prefix() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let name = String(cString: interface.ifa_name)
            guard name == "en0",
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let address = String(cString: hostBuffer)
            let components = address.split(separator: ".")
            guard components.count == 4 else {
                continue
            }

            return components.prefix(3).joined(separator: ".")
        }

        return nil
    }
}
