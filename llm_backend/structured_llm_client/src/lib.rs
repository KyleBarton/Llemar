use serde::{de::DeserializeOwned, Serialize, Deserialize};
use async_openai::{config::OpenAIConfig, Client};
use async_openai::types::{ChatCompletionRequestAssistantMessageArgs, ChatCompletionRequestAssistantMessageContent, ChatCompletionRequestMessage, ChatCompletionRequestUserMessage, ChatCompletionRequestUserMessageArgs, ChatCompletionRequestUserMessageContent, CreateChatCompletionRequest, CreateChatCompletionRequestArgs, ResponseFormat, ResponseFormatJsonSchema};
use futures::{Future, StreamExt};
use serde_json::json;
use std::fmt::Write;

pub struct LlmConversation {
  messages: Vec<ChatCompletionRequestMessage>,
}
impl LlmConversation {
  pub fn new() -> Self {
    Self {
      messages: Vec::new(),
    }
  }

  pub async fn chat<T>(&mut self, prompt: String, client: impl OpenAiChatClient) -> Result<CompletionResponse<T>, String>
  where T: StructuredContent
  {
    // TODO hacky
    let mut msgs_with_new_prompt = self.messages.clone();
    msgs_with_new_prompt.push(ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage {
      content: ChatCompletionRequestUserMessageContent::Text(prompt.clone()),
      name: None,
    }));


    let mut request = request_from_prompt::<T>(&prompt); // TODo the borrow here and clone above can be simplified once I delete some code

    request.messages = msgs_with_new_prompt;

    //End hackiness

    match client.chat_complete(request).await {
      Err(s) => Err(s),
      Ok(resp) => {
	self.add_user_message(prompt.clone(), None);
	let structured_resp : T = serde_json::from_str(&resp).unwrap(); // TODO handle
	self.add_assistant_message(resp);
	Ok(CompletionResponse::from_prompt(&prompt).with_content(structured_resp))
      }
    }
  }
  
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


pub struct OpenAiClientImpl {
  openai_client: Client<OpenAIConfig>,
}

impl Default for OpenAiClientImpl{
    fn default() -> Self {
        Self::new()
    }
}

impl OpenAiClientImpl {
  pub fn new() -> Self {
    Self {
      openai_client: Client::new(),
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
	Err(e) => {
	  println!("Error from open ai: {}", e);
	  return Err(e.to_string());
	}
      }
      
    };
    Ok(response_writer)
  }
}

pub trait OpenAiChatClient{
  fn chat_complete(&self, request: CreateChatCompletionRequest) -> impl Future<Output=Result<String, String>>;
}

impl OpenAiChatClient for OpenAiClientImpl {
    fn chat_complete(&self, request: CreateChatCompletionRequest) -> impl Future<Output=Result<String, String>> {
        self.from_stream(request)
    }
}

fn request_from_prompt<T>(prompt: &str) -> async_openai::types::CreateChatCompletionRequest
where T: StructuredContent
{

  let response_format = ResponseFormat::JsonSchema{
    json_schema: ResponseFormatJsonSchema {
      description: Some(T::description()),
      name: T::name(),
      schema: Some(T::schema()),
      strict: Some(true),
    }
  };

  let request = CreateChatCompletionRequestArgs::default()
    .model("gpt-4o-2024-08-06")
    .max_tokens(256u32)
    .messages([ChatCompletionRequestUserMessageArgs::default()
	       .content(prompt)
	       .build().unwrap()
	       .into()])
    .response_format(response_format)
    .build().unwrap();
  request
}

// TODO rename I think
#[derive(Debug, PartialEq, Eq)]
pub struct CompletionResponse<T>{
  prompt: String,
  pub body: Option<T>, // TODO see main.rs this needs wrapping
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

impl StructuredContent for TestContent {
    fn name() -> String {
        "Test Content".into()
    }

    fn description() -> String {
        "A sample structured object that contains only a simple id field".into()
    }

    fn schema() -> serde_json::Value {
      json!({
	"type": "object",
	"properties": {
	  "id": {
	    "type": "number",
	    "description": "the id of the object"
	  }
	}
      })
    }
}

#[derive(Debug, PartialEq, Serialize, Deserialize, Default)]
pub struct ConversationExecutableSplitContent {
  conversational: String,
  executable: String,
}

impl StructuredContent for ConversationExecutableSplitContent {
  fn name() -> String {
    "Conversational_Executable".into()
  }

  fn description() -> String {
    "An object representing both conversational response content and structured executable content".into()
  }

  //TODO so much of this needs to be enforced
  fn schema() -> serde_json::Value {
    json!({
      "type": "object",
      "additionalProperties": false,
      "required": ["conversational", "executable"],
      "properties": {
	"conversational": {
	  "type": "string",
	  "description": "the field for plain language, conversational chat response content"
	},
	"executable": {
	  "type": "string",
	  "description": "the field for any executable code produced as part of the response content. This should be left blank unless executable content is explicitly requested"
	}
      }
    })
  }
}

pub trait StructuredContent : Serialize + DeserializeOwned + Default {
  fn name() -> String;
  fn description() -> String;
  fn schema() -> serde_json::Value;
}

#[cfg(test)]
mod tests {
  use async_openai::types::{ChatCompletionRequestMessage, ChatCompletionRequestUserMessage, ChatCompletionRequestUserMessageContent, ResponseFormat, ResponseFormatJsonSchema};
  use futures::future;

  use super::*;

  //Tests needed: response is not serializable to the desired content; server error response from llm client for whatever reason; additionalProperties=false and required=[all the fields] are included in the given schema

  #[derive(Default)]
  struct TestClient;
  impl OpenAiChatClient for TestClient {
    fn chat_complete(&self, _request: CreateChatCompletionRequest) -> impl Future<Output=Result<String, String>> {
      let content = serde_json::to_string(&TestContent { id : 1}).unwrap();
      return future::ready(Ok(content))
    }
  }

  #[tokio::test]
  async fn returns_structured_data_v2() {
    let test_client = TestClient::default();

    let mut conversation = LlmConversation::new();

    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";

    let structured_resp : CompletionResponse<TestContent> = conversation.chat(prompt.to_string(), test_client).await.unwrap();

    let test_content = TestContent { id: 1};

    assert_eq!(structured_resp, CompletionResponse::from_prompt(prompt).with_content(test_content));
  }

  #[test]
  fn creates_request_with_given_prompt() {
    // Given
    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";

    // When
    let openai_request = request_from_prompt::<TestContent>(prompt);

    // Then
    let expected_prompt_messages = vec!(
      ChatCompletionRequestMessage::User(ChatCompletionRequestUserMessage { content: ChatCompletionRequestUserMessageContent::Text(String::from(prompt)), name: None})
    );

    assert_eq!(openai_request.messages, expected_prompt_messages)
  }

  #[test]
  fn creates_request_with_structured_instructions() {
    // Given
    let prompt = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";

    // When
    let openai_request = request_from_prompt::<TestContent>(prompt);

    let expected_response_format = Some(ResponseFormat::JsonSchema{
      json_schema: ResponseFormatJsonSchema {
	schema: Some(TestContent::schema()),
	description: Some(TestContent::description()),
	name: TestContent::name(),
	strict: Some(true),
      }
    });

    assert_eq!(openai_request.response_format, expected_response_format)

  }


  #[tokio::test]
  async fn chat_messages_extend_conversation() {
    //given
    let mut conversation = LlmConversation::new();
    let prompt1 = "Respond with exactly the following json content with nothing else: { \"id\": 1 }";
    let prompt2 = "Ok, now do it again";

    conversation.chat::<TestContent>(prompt1.to_string(), TestClient::default()).await.unwrap();

    let user_msgs : Vec<&ChatCompletionRequestMessage> = conversation.messages.iter().filter(|s| if let ChatCompletionRequestMessage::User(..) = s {true} else {false} ).collect();

    assert_eq!(user_msgs.len(), 1);

    conversation.chat::<TestContent>(prompt2.to_string(), TestClient::default()).await.unwrap();

    let added_usr_msgs : Vec<&ChatCompletionRequestMessage> = conversation.messages.iter().filter(|s| if let ChatCompletionRequestMessage::User(..) = s {true} else {false} ).collect();

    assert_eq!(added_usr_msgs.len(), 2);

    let assistant_msgs : Vec<&ChatCompletionRequestMessage> = conversation.messages
      .iter()
      .filter(|s| if let ChatCompletionRequestMessage::Assistant(..) = s { true} else {false} )
      .collect();

    let expected_assistant_msg = ChatCompletionRequestAssistantMessageArgs::default()
      .content(serde_json::to_string(&TestContent { id: 1}).unwrap())
      .build()
      .unwrap();
    assert_eq!(assistant_msgs, vec!(
      // Two of them since I hit the endpoint twice
      &ChatCompletionRequestMessage::Assistant(expected_assistant_msg.clone()),
      &ChatCompletionRequestMessage::Assistant(expected_assistant_msg),
    ))
  }
}
