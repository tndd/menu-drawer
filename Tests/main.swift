import Cocoa

@main struct Tests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ ok: Bool,_ message: String) { precondition(ok,message); count += 1; print("成功：\(message)") }
        let plan = RestorePosition(right:[30,40],left:[20,10])
        let a = plan.destination(available:[10,20,30,40],hidden:[30],boundary:99)
        check(a.0 == 40 && a.1,"収納中の隣接アイコンを避け、次の表示中アイコンの左へ戻す")
        let b = plan.destination(available:[10,20],hidden:[],boundary:99)
        check(b.0 == 20 && !b.1,"右隣が終了していたら元の左隣の右へ戻す")
        let c = plan.destination(available:[],hidden:[],boundary:99)
        check(c.0 == 99 && !c.1,"隣接アイコンが全て終了していたら境界の表示側へ戻す")
        let d = plan.destination(available:[10,20,30,40],hidden:[10,20,30,40],boundary:99)
        check(d.0 == 99 && !d.1,"全ての隣接アイコンが収納中でも収納側に戻さない")
        func icon(_ bundle: String,_ detail: String,_ width: CGFloat) -> MenuIcon { MenuIcon(id:1,pid:1,bundleID:bundle,name:"検証",detail:detail,frame:CGRect(x:0,y:0,width:width,height:37),stableKey:bundle) }
        check(icon("third.party.app","",40).protectedReason == nil,"他アプリの設定キーの有無に依存せず移動対象にする")
        check(icon("com.apple.controlcenter","Control Center",34).protectedReason != nil,"macOS固定のコントロールセンターを識別")
        check(icon("com.apple.controlcenter","時計",150).protectedReason != nil,"macOS固定の時計を識別")
        check(icon("com.apple.controlcenter","AudioVideoModule",34).protectedReason != nil,"録画・録音の保護表示を識別")
        check(icon("com.apple.controlcenter","WiFi",34).protectedReason == nil,"動かせるシステムアイコンまで一律に除外しない")
        print("\(count)検証に成功")
    }
}
