use serde::{de::DeserializeOwned, Serialize, Deserialize};
use async_openai::{config::OpenAIConfig, types::CreateCompletionRequestArgs, Client};
use futures::StreamExt;

pub struct LlmClient {
  openai_client: Client<OpenAIConfig>,
}

impl LlmClient {
  pub fn new() -> Self {
    Self {
      openai_client: Client::new(),
    }
  }

  pub async fn complete<T>(&self, prompt: &str) -> Result<CompletionResponse<T>, String>
    where T: Serialize + DeserializeOwned
  {
    match self.from_stream(prompt).await {
      Err(s) => Err(s),
      Ok(raw) => {
	let deser : Result<T, serde_json::Error> =  serde_json::from_str(raw);
	match deser {
	  Err(e) => Err(e.to_string()),
	  Ok(t) => Ok(CompletionResponse::from_prompt(prompt).with_content(t))
	}
      }
    }
    
  }

  async fn from_stream(&self, prompt: &str) -> Result<&str, String> {
    let request = CreateCompletionRequestArgs::default()
      .model("gpt-3.5-turbo-instruct") // TODO doesn't seem to work with any other models?
      .n(1)
      .prompt(prompt)
      .stream(true)
      .max_tokens(200_u32)
      .build().unwrap(); // TODO handle

    let mut stream = self.openai_client.completions().create_stream(request).await.unwrap(); // TODO handle

    while let Some(response) = stream.next().await {
      match response {
	Ok(cont) => println!("done"),
	Err(e) => return Err(e.to_string())
      }
      
    };
    Ok("{ \"id\": 1 }")
  }
}

#[derive(Debug, PartialEq, Eq)]
pub struct CompletionResponse<T>{
  prompt: String,
  body: Option<T>,
}

impl <T> CompletionResponse<T>
  where T: Serialize + DeserializeOwned
{
  pub fn from_prompt(prompt: &str) -> Self {
    Self {
      prompt: String::from(prompt),
      body: None,
    }
  }

  pub fn with_content(mut self, content: T) -> Self {
    self.body = Some(content);
    self
  }
}

#[derive(Debug, PartialEq, Serialize, Deserialize, Default)]
struct TestContent {
  id: u8,
}

#[cfg(test)]
mod tests {
  use super::*;

  #[tokio::test]
  async fn returns_structured_data() {
    let client = LlmClient::new();

    let prompt = "This is a prompt";
    let structured_resp : CompletionResponse<TestContent> = client.complete(prompt).await.unwrap();

    let test_content = TestContent { id: 1};

    assert_eq!(structured_resp, CompletionResponse::from_prompt(prompt).with_content(test_content));
  }
}
