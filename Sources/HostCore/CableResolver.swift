import Foundation
import Network
import dnssd

/// Risolve il servizio Bonjour dell'iMac solo sul cavo (Ponte Thunderbolt).
///
/// Con Wi-Fi e cavo attivi insieme, l'iMac risponde alla risoluzione del nome a volte
/// solo dal Wi-Fi: Network.framework, a cui il Wi-Fi è vietato, resta allora senza strada.
/// Il Ponte Thunderbolt non porta a Internet, quindi Network.framework non lo offre come
/// interfaccia da richiedere: la domanda va fatta direttamente a mDNSResponder.
final class CableResolver {
    private let interfaceIndex: UInt32
    private let interfaceName: String
    private var completion: ((NWEndpoint?) -> Void)?
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var port: UInt16 = 0
    private var retainedSelf: CableResolver? // vivo finché la risoluzione non finisce

    /// `completion` arriva sulla coda principale, con nil se il cavo non risponde in tempo.
    static func resolve(name: String, type: String, domain: String,
                        timeout: TimeInterval = 5,
                        completion: @escaping (NWEndpoint?) -> Void) {
        guard let (index, interfaceName) = cableInterface() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let resolver = CableResolver(interfaceIndex: index, interfaceName: interfaceName)
        resolver.start(name: name, type: type, domain: domain, timeout: timeout, completion: completion)
    }

    /// Il primo Ponte Thunderbolt attivo con un indirizzo IPv4.
    static func cableInterface() -> (UInt32, String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            guard name.hasPrefix("bridge"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  ifa.ifa_addr?.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let index = if_nametoindex(ifa.ifa_name)
            if index != 0 { return (index, name) }
        }
        return nil
    }

    private init(interfaceIndex: UInt32, interfaceName: String) {
        self.interfaceIndex = interfaceIndex
        self.interfaceName = interfaceName
    }

    private func start(name: String, type: String, domain: String, timeout: TimeInterval,
                       completion: @escaping (NWEndpoint?) -> Void) {
        self.completion = completion
        retainedSelf = self
        let context = Unmanaged.passUnretained(self).toOpaque()

        let status = DNSServiceResolve(&resolveRef, 0, interfaceIndex, name, type, domain, { _, _, _, error, _, host, port, _, _, context in
            guard let context else { return }
            let resolver = Unmanaged<CableResolver>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let host else { return resolver.finish(nil) }
            resolver.resolved(host: String(cString: host), port: UInt16(bigEndian: port))
        }, context)
        guard status == kDNSServiceErr_NoError, let resolveRef else { return finish(nil) }
        DNSServiceSetDispatchQueue(resolveRef, .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    private func resolved(host: String, port: UInt16) {
        guard addressRef == nil else { return }
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        let status = DNSServiceGetAddrInfo(&addressRef, 0, interfaceIndex, protocols, host, { _, _, _, error, _, address, _, context in
            guard let context else { return }
            let resolver = Unmanaged<CableResolver>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let address else { return }
            resolver.found(address)
        }, context)
        guard status == kDNSServiceErr_NoError, let addressRef else { return finish(nil) }
        DNSServiceSetDispatchQueue(addressRef, .main)
    }

    private func found(_ address: UnsafePointer<sockaddr>) {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let text: String
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return }
            text = String(cString: buffer)
        case AF_INET6:
            var ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &ip, &buffer, socklen_t(buffer.count)) != nil else { return }
            // Gli indirizzi fe80:: valgono solo su un'interfaccia: va indicata.
            text = String(cString: buffer) + "%" + interfaceName
        default:
            return
        }
        guard let port = NWEndpoint.Port(rawValue: port) else { return finish(nil) }
        print("Uso il cavo: \(text)")
        finish(.hostPort(host: NWEndpoint.Host(text), port: port))
    }

    private func finish(_ endpoint: NWEndpoint?) {
        guard let completion else { return }
        self.completion = nil
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        if let addressRef { DNSServiceRefDeallocate(addressRef) }
        resolveRef = nil
        addressRef = nil
        completion(endpoint)
        retainedSelf = nil
    }
}
