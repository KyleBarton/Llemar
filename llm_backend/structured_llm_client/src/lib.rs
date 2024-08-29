use std::str::FromStr;

use serde::{Serialize, Deserialize};

pub struct LlmClient;

impl LlmClient {
  pub fn new() -> Self {
    Self
  }

  pub fn complete(&self, prompt: &str) -> Result<BasicResponse, &str> {
    Ok(BasicResponse::from_prompt(prompt))
  }
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BasicResponse {
  prompt: String,
  id: u8,
}

impl BasicResponse {
  pub fn new() -> Self {
    Self {
      prompt: String::new(),
      id: 1,
    }
  }

  // TODO remove this eventually
  pub fn from_prompt(prompt: &str) -> Self {
    Self {
      prompt: String::from_str(prompt).unwrap(),
      id: 1,
    }
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn returns_structured_data() {
    let client = LlmClient::new();

    let prompt = "This is a prompt";
    let structured_resp : BasicResponse = client.complete(prompt).unwrap();

    assert_eq!(structured_resp, BasicResponse::from_prompt(prompt));
  }

}
