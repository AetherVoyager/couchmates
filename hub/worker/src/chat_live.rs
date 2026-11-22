//! `ChatLive`: the Durable Object that holds every app's chat WebSocket and
//! pushes new messages to them. It keeps nothing itself; messages live in D1.
//!
//! Sockets use the hibernation API, so the object sleeps (and costs nothing)
//! between messages. Each socket is tagged with its user's id, which only the
//! Worker sets (`chat::USER_HEADER`), after checking the device token. The
//! apps' keep-alive `ping` is answered with `pong` without waking it.

use couchmates_hub_core::chat::{Push, USER_HEADER};
use worker::{
    DurableObject, Env, Request, Response, Result, State, WebSocket, WebSocketIncomingMessage, WebSocketPair,
    durable_object, worker_sys::WebSocketRequestResponsePair,
};

#[durable_object]
pub struct ChatLive {
    state: State,
}

impl DurableObject for ChatLive {
    fn new(state: State, _env: Env) -> Self {
        if let Ok(pair) = WebSocketRequestResponsePair::new("ping", "pong") {
            state.set_websocket_auto_response(&pair);
        }
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        match req.path().as_str() {
            "/live" => {
                let Some(user) = req.headers().get(USER_HEADER)?.filter(|u| !u.is_empty()) else {
                    return Response::error("No user", 400);
                };
                let pair = WebSocketPair::new()?;
                self.state.accept_websocket_with_tags(&pair.server, &[&user]);
                Response::from_websocket(pair.client)
            }
            "/push" => {
                let push: Push = req.json().await?;
                let sockets = match &push.to {
                    None => self.state.get_websockets(),
                    Some(users) => users.iter().flat_map(|u| self.state.get_websockets_with_tag(u)).collect(),
                };
                for socket in sockets {
                    // A socket that's closing just misses it; the app catches up.
                    let _ = socket.send_with_str(&push.frame);
                }
                Response::ok("ok")
            }
            _ => Response::error("Not found", 404),
        }
    }

    async fn websocket_message(&self, _ws: WebSocket, _message: WebSocketIncomingMessage) -> Result<()> {
        // Apps only listen; anything but the auto-answered ping is ignored.
        Ok(())
    }

    async fn websocket_close(&self, ws: WebSocket, code: usize, _reason: String, _was_clean: bool) -> Result<()> {
        // Finish the closing handshake. 1005/1006 can't be sent back.
        let code = if (1000..=4999).contains(&code) && code != 1005 && code != 1006 { code as u16 } else { 1000 };
        let _ = ws.close(Some(code), Some("bye"));
        Ok(())
    }

    async fn websocket_error(&self, _ws: WebSocket, _error: worker::Error) -> Result<()> {
        Ok(())
    }
}
