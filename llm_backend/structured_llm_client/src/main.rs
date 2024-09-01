use structured_llm_client::LlmClient;


// This is where I'll actually call the stuff I'm building in lib.rs
fn main() {
  let _llm_client = LlmClient::new();
  println!("hello world, client created.")
}
