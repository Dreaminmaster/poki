
// Reads releases as tab-separated lines ("R", tag, prerelease 0 or 1, published_at; then one
// "A", name line per file) in GitHub's order and prints what each channel picks.
fn main() {
    use std::io::BufRead;
    let mut list: Vec<GhRelease> = vec![];
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "R" => list.push(GhRelease { tag_name: f[1].into(), prerelease: f[2] == "1", draft: false, published_at: Some(f[3].into()), body: None, html_url: None, assets: vec![] }),
            "A" => list.last_mut().unwrap().assets.push(GhAsset { name: f[1].into(), browser_download_url: String::new() }),
            _ => {}
        }
    }
    // As list() does after reading GitHub's answer.
    list.sort_by(|a, b| b.published_at.cmp(&a.published_at));
    for channel in Channel::ALL {
        match pick(&list, channel) {
            Some(r) => println!("app\t{}\t{}\t{}\t{}\t{}", channel.id(), r.tag, r.ipa_name, r.version, r.build),
            None => println!("app\t{}\tnone", channel.id()),
        }
        match pick_desktop(&list, channel, "-macos.dmg") {
            Some((r, a, v)) => println!("setup\t{}\t{}\t{}\t{}", channel.id(), r.tag_name, a.name, v),
            None => println!("setup\t{}\tnone", channel.id()),
        }
    }
}
