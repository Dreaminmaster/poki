//! Lists the test builds as Poki Setup's Developer page would: POKI_GITHUB_TOKEN=... cargo run --example test-builds-probe
#[tokio::main]
async fn main() {
    let l = poki_setup_core::devbuilds::list(true).await.expect("list");
    println!("{} of {} builds, branches {:?}", l.builds.len(), l.total, l.branches.len());
    for b in l.builds.iter().take(8) {
        println!("{:?} {} #{} {} {} {:?} pr={:?} {}MB", b.state, b.workflow, b.run_number, b.branch, b.short_sha(), b.actor, b.pr.as_ref().map(|p| p.number), b.size / 1_000_000);
    }
}
