import Foundation

/// 林道の天気予報（Open-Meteo）。林道の両端の中間地点の予報を取る。
/// 標高は Open-Meteo が地点の標高データで補正するので、山の上の気温に近くなる。
/// 出典表示が必要（Weather data by Open-Meteo.com、CC BY 4.0）。
@MainActor
final class WeatherStore: ObservableObject {
    struct Day: Identifiable, Equatable {
        let id: String          // 日付（yyyy-MM-dd）
        let label: String       // 今日・明日・あさって
        let code: Int           // WMO 天気コード
        let maxTemp: Double
        let minTemp: Double
        let rainChance: Int?    // 降水確率（%）
        let rainMm: Double      // 降水量（mm）
    }

    struct Forecast: Equatable {
        let days: [Day]
        let yesterdayRainMm: Double?
        let elevation: Double?
        let fetchedAt: Date
    }

    enum State: Equatable {
        case loading
        case loaded(Forecast)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private static let refreshInterval: TimeInterval = 30 * 60

    func state(of road: String) -> State? { states[road] }

    func load(road: String, latitude: Double, longitude: Double) async {
        if case .loaded(let f) = states[road], Date().timeIntervalSince(f.fetchedAt) < Self.refreshInterval { return }
        if states[road] == nil { states[road] = .loading }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", latitude)),
            .init(name: "longitude", value: String(format: "%.4f", longitude)),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum"),
            .init(name: "timezone", value: "Asia/Tokyo"),
            .init(name: "past_days", value: "1"),
            .init(name: "forecast_days", value: "3"),
        ]
        do {
            let (data, response) = try await URLSession.shared.data(from: c.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            states[road] = .loaded(try Self.parse(data))
        } catch {
            // 前に取れた予報があれば、それを残す
            if case .loaded = states[road] { return }
            states[road] = .failed("天気予報を取得できません（通信できるときに表示）")
        }
    }

    private struct Response: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]
            let precipitation_sum: [Double?]
        }
        let daily: Daily
        let elevation: Double?
    }

    static func parse(_ data: Data) throws -> Forecast {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let d = r.daily
        let labels = ["昨日", "今日", "明日", "あさって"]
        var days: [Day] = []
        for i in d.time.indices.dropFirst() {   // 先頭は昨日（雨量だけ使う）
            guard let code = d.weather_code[i], let hi = d.temperature_2m_max[i], let lo = d.temperature_2m_min[i] else { continue }
            days.append(Day(id: d.time[i], label: i < labels.count ? labels[i] : d.time[i],
                            code: code, maxTemp: hi, minTemp: lo,
                            rainChance: d.precipitation_probability_max[i],
                            rainMm: d.precipitation_sum[i] ?? 0))
        }
        let yesterday = d.precipitation_sum.first ?? nil
        return Forecast(days: days, yesterdayRainMm: yesterday, elevation: r.elevation, fetchedAt: Date())
    }

    /// WMO 天気コード → SF Symbols と日本語
    static func describe(_ code: Int) -> (symbol: String, text: String) {
        switch code {
        case 0: return ("sun.max.fill", "晴れ")
        case 1, 2: return ("cloud.sun.fill", "晴れ時々曇り")
        case 3: return ("cloud.fill", "曇り")
        case 45, 48: return ("cloud.fog.fill", "霧")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "霧雨")
        case 61, 63, 80, 81: return ("cloud.rain.fill", "雨")
        case 65, 82: return ("cloud.heavyrain.fill", "強い雨")
        case 66, 67: return ("cloud.sleet.fill", "みぞれ")
        case 71, 73, 75, 77, 85, 86: return ("cloud.snow.fill", "雪")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "雷雨")
        default: return ("cloud.fill", "—")
        }
    }
}
