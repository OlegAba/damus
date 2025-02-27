//
//  NostrConnection.swift
//  damus
//
//  Created by William Casarin on 2022-04-02.
//

import Foundation
import Starscream

enum NostrConnectionEvent {
    case ws_event(WebSocketEvent)
    case nostr_event(NostrResponse)
}

final class RelayConnection: WebSocketDelegate {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isReconnecting = false
    
    private(set) var last_connection_attempt: TimeInterval = 0
    private lazy var socket = {
        let req = URLRequest(url: url)
        let socket = WebSocket(request: req, compressionHandler: .none)
        socket.delegate = self
        return socket
    }()
    private var handleEvent: (NostrConnectionEvent) -> ()
    private let url: URL

    init(url: URL, handleEvent: @escaping (NostrConnectionEvent) -> ()) {
        self.url = url
        self.handleEvent = handleEvent
    }
    
    func reconnect() {
        if isConnected {
            isReconnecting = true
            disconnect()
        } else {
            // we're already disconnected, so just connect
            connect(force: true)
        }
    }
    
    func connect(force: Bool = false) {
        if !force && (isConnected || isConnecting) {
            return
        }
        
        isConnecting = true
        last_connection_attempt = Date().timeIntervalSince1970
        socket.connect()
    }

    func disconnect() {
        socket.disconnect()
        isConnected = false
        isConnecting = false
    }

    func send(_ req: NostrRequest) {
        guard let req = make_nostr_req(req) else {
            print("failed to encode nostr req: \(req)")
            return
        }

        socket.write(string: req)
    }
    
    // MARK: - WebSocketDelegate
    
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected:
            self.isConnected = true
            self.isConnecting = false

        case .disconnected:
            self.isConnecting = false
            self.isConnected = false
            if self.isReconnecting {
                self.isReconnecting = false
                self.connect()
            }

        case .cancelled, .error:
            self.isConnecting = false
            self.isConnected = false

        case .text(let txt):
            if txt.utf8.count > 2000 {
                DispatchQueue.global(qos: .default).async {
                    if let ev = decode_nostr_event(txt: txt) {
                        DispatchQueue.main.async {
                            self.handleEvent(.nostr_event(ev))
                        }
                        return
                    }
                }
            } else {
                if let ev = decode_nostr_event(txt: txt) {
                    handleEvent(.nostr_event(ev))
                    return
                }
            }

            print("decode failed for \(txt)")
            // TODO: trigger event error

        default:
            break
        }

        handleEvent(.ws_event(event))
    }
}

func make_nostr_req(_ req: NostrRequest) -> String? {
    switch req {
    case .subscribe(let sub):
        return make_nostr_subscription_req(sub.filters, sub_id: sub.sub_id)
    case .unsubscribe(let sub_id):
        return make_nostr_unsubscribe_req(sub_id)
    case .event(let ev):
        return make_nostr_push_event(ev: ev)
    }
}

func make_nostr_push_event(ev: NostrEvent) -> String? {
    guard let event = encode_json(ev) else {
        return nil
    }
    let encoded = "[\"EVENT\",\(event)]"
    print(encoded)
    return encoded
}

func make_nostr_unsubscribe_req(_ sub_id: String) -> String? {
    "[\"CLOSE\",\"\(sub_id)\"]"
}

func make_nostr_subscription_req(_ filters: [NostrFilter], sub_id: String) -> String? {
    let encoder = JSONEncoder()
    var req = "[\"REQ\",\"\(sub_id)\""
    for filter in filters {
        req += ","
        guard let filter_json = try? encoder.encode(filter) else {
            return nil
        }
        let filter_json_str = String(decoding: filter_json, as: UTF8.self)
        req += filter_json_str
    }
    req += "]"
    return req
}
