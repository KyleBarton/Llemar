use std::io;

use structured_llm_client::{LlmConversation, OpenAiClientImpl, ConversationExecutableSplitContent};


// This is where I'll actually call the stuff I'm building in lib.rs
#[tokio::main]
async fn main() {
  let mut converation = LlmConversation::new();
  loop {
    let mut input = String::new();

    println!("Prompt: ");

    match io::stdin().read_line(&mut input) {
      Ok(_) => {
	match input.as_str().trim() {
	  "quit()" => {
	    println!("exiting program");
	    break;
	  }
	  prompt => {
	    match converation.chat::<ConversationExecutableSplitContent>(prompt.to_string(), OpenAiClientImpl::new()).await {
	      Ok(resp) => {
		println!("{}", serde_json::to_string(&resp.body).unwrap());
	      },
	      Err(e) => {
		println!("Received an error: {}", e);
	      }
	    }
	  }
	}
      }
      Err(e) => {
	println!("error: {}", e);
	break;
      }
    }
  }
}
