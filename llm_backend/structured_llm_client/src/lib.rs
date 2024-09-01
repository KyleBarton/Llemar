use serde::{de::DeserializeOwned, Serialize, Deserialize};
use async_openai::{config::OpenAIConfig, Client};
use async_openai::types::{ChatCompletionRequestAssistantMessageArgs, ChatCompletionRequestAssistantMessageContent, ChatCompletionRequestMessage, ChatCompletionRequestUserMessage, ChatCompletionRequestUserMessageArgs, ChatCompletionRequestUserMessageContent, CreateChatCompletionRequest, CreateChatCompletionRequestArgs};
use futures::StreamExt;
use std::fmt::Write;

pub struct LlmConversation {
  messages: Vec<ChatCompletionRequestMessage>,
}
impl LlmConversation {
  pub fn add_user_message(&mut self, message: String, name: Option<String>) {
    self.messages.push(
      ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage {
	content: ChatCompletionRequestUserMessageContent::Text(message),
	name,
      }),
    )
  }
  pub fn add_assistant_message(&mut self, message: String) {
    let assistant_message = ChatCompletionRequestAssistantMessageArgs::default()
      .content(ChatCompletionRequestAssistantMessageContent::Text(message))
      .build().unwrap(); // TODO
    self.messages.push(
      ChatCompletionRequestMessage::Assistant(assistant_message)
    )
  }
}

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
    let request = request_from_prompt(prompt);
    match self.from_stream(request).await {
      Err(s) => Err(s),
      Ok(raw) => {
	to_structured_content(raw, prompt)
      }
    }
    
  }

  async fn from_stream(&self, request: CreateChatCompletionRequest) -> Result<String, String> {
    let mut stream = self.openai_client.chat().create_stream(request).await.unwrap(); // TODO handle

    let mut response_writer = String::new();
    while let Some(response) = stream.next().await {
      match response {
	Ok(cont) => {
	  cont.choices.iter().for_each(|chat_choice| {
	  if let Some(ref content) = chat_choice.delta.content {
	    write!(response_writer, "{}", content).unwrap();
	  }
	});
	},
	Err(e) => return Err(e.to_string())
      }
      
    };
    println!("Writing {}", &response_writer);
    Ok(response_writer)
  }
}

fn to_structured_content<T>(raw: String, prompt: &str) -> Result<CompletionResponse<T>, String> where T: Serialize + DeserializeOwned {
    let deser : Result<T, serde_json::Error> =  serde_json::from_str(&raw);
    match deser {
	      Err(e) => Err(e.to_string()),
	      Ok(t) => Ok(CompletionResponse::from_prompt(prompt).with_content(t))
	    }
}

fn request_from_prompt(prompt: &str) -> async_openai::types::CreateChatCompletionRequest {
    let request = CreateChatCompletionRequestArgs::default()
        .model("gpt-4o")
        .max_tokens(256u32)
        .messages([ChatCompletionRequestUserMessageArgs::default()
            .content(prompt)
            .build().unwrap()
            .into()])
        .build().unwrap();
    request
}

// TODO rename I think
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

#[derive(Debug, PartialEq, Serialize, Deserialize)]
struct TestContent {
  id: u8,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
struct ConversationExecutableSplitContent {
  conversational: String,
  executable: String,
}

#[cfg(test)]
mod tests {
  use async_openai::types::{ChatCompletionRequestMessage, ChatCompletionRequestUserMessage, ChatCompletionRequestUserMessageContent};
use serde_json::json;

use super::*;

  #[tokio::test]
  #[ignore = "only works with a valid env, should be ignored most of the time"]
  async fn returns_structured_data() {
    let client = LlmClient::new();

    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";
    let structured_resp : CompletionResponse<TestContent> = client.complete(prompt).await.unwrap();

    let test_content = TestContent { id: 1};

    assert_eq!(structured_resp, CompletionResponse::from_prompt(prompt).with_content(test_content));
  }

  #[test]
  fn creates_request_with_given_prompt() {
    // Given
    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";

    // When
    let openai_request = request_from_prompt(prompt);

    // Then
    let expected_prompt_messages = vec!(
      ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage { content: ChatCompletionRequestUserMessageContent::Text(String::from(prompt)), name: None})
    );

    assert_eq!(openai_request.messages, expected_prompt_messages)
  }

  #[test]
  fn generates_structured_response_from_content() {
    // Given
    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";
    let result = "{ \"id\": 1 }".to_string();
    // When
    let structured_response : CompletionResponse<TestContent> = to_structured_content(result, prompt).unwrap();
    
    // Then
    assert_eq!(&structured_response.prompt, prompt);
    assert_eq!(structured_response.body, Some(TestContent { id: 1 }));
  }

  #[test]
  #[ignore = "just playing around"]
  fn foo() {
    let content = TestContent { id: 0 };

    
    // Output of this
    //  left: ""
    // right: Object {"id": Number(0)}
    assert_eq!("", json!(content));
  }
}
