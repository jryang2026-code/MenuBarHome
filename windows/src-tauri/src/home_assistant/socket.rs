use std::{
    future::poll_fn,
    io::{self, Read, Write},
    pin::Pin,
    sync::{Arc, LazyLock},
    task::{Context, Poll, Waker},
};

use rustls::{pki_types::ServerName, ClientConfig, RootCertStore};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
};
use tungstenite::{handshake::HandshakeError, Error, Message, WebSocket};

trait HaIo: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> HaIo for T {}

// One actor polls both directions, so the synchronous codec can use the actor's
// waker for all I/O. WouldBlock leaves the codec's framing state intact.
struct AsyncIo {
    stream: Box<dyn HaIo>,
    waker: Waker,
}

fn io_result<T>(result: Poll<io::Result<T>>) -> io::Result<T> {
    match result {
        Poll::Ready(result) => result,
        Poll::Pending => Err(io::ErrorKind::WouldBlock.into()),
    }
}

impl Read for AsyncIo {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut buf = ReadBuf::new(buf);
        let mut cx = Context::from_waker(&self.waker);
        io_result(Pin::new(&mut *self.stream).poll_read(&mut cx, &mut buf))?;
        Ok(buf.filled().len())
    }
}

impl Write for AsyncIo {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut cx = Context::from_waker(&self.waker);
        io_result(Pin::new(&mut *self.stream).poll_write(&mut cx, buf))
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut cx = Context::from_waker(&self.waker);
        io_result(Pin::new(&mut *self.stream).poll_flush(&mut cx))
    }
}

static TLS_CONFIG: LazyLock<Arc<ClientConfig>> = LazyLock::new(|| {
    let mut roots = RootCertStore::empty();
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    Arc::new(
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("the ring provider supports the default TLS versions")
            .with_root_certificates(roots)
            .with_no_client_auth(),
    )
});

pub(super) struct Socket(WebSocket<AsyncIo>);

fn would_block(error: &Error) -> bool {
    matches!(error, Error::Io(error) if error.kind() == io::ErrorKind::WouldBlock)
}

impl Socket {
    pub(super) async fn upgrade(
        url: &str,
        tls_host: Option<&str>,
        tcp: TcpStream,
    ) -> Result<Self, String> {
        let stream: Box<dyn HaIo> = if let Some(host) = tls_host {
            let name = ServerName::try_from(host.to_owned())
                .map_err(|_| "Invalid Home Assistant TLS host")?;
            let connector = tokio_rustls::TlsConnector::from(TLS_CONFIG.clone());
            Box::new(connector.connect(name, tcp).await
                .map_err(|_| "Home Assistant TLS handshake failed")?)
        } else {
            Box::new(tcp)
        };

        let mut stream = Some(stream);
        let mut handshake = None;
        poll_fn(|cx| {
            let result = if let Some(stream) = stream.take() {
                tungstenite::client(url, AsyncIo { stream, waker: cx.waker().clone() })
            } else {
                let mut handshake: tungstenite::handshake::MidHandshake<
                    tungstenite::handshake::client::ClientHandshake<AsyncIo>,
                > = handshake.take().expect("interrupted WebSocket handshake");
                handshake.get_mut().get_mut().waker.clone_from(cx.waker());
                handshake.handshake()
            };
            match result {
                Ok((socket, _)) => Poll::Ready(Ok(Self(socket))),
                Err(HandshakeError::Interrupted(partial)) => {
                    handshake = Some(partial);
                    Poll::Pending
                }
                Err(HandshakeError::Failure(_)) => {
                    Poll::Ready(Err("Home Assistant handshake failed".into()))
                }
            }
        }).await
    }

    pub(super) async fn read(&mut self) -> Result<Message, String> {
        poll_fn(|cx| {
            self.0.get_mut().waker.clone_from(cx.waker());
            match self.0.read() {
                Ok(Message::Close(_)) => Poll::Ready(Err("Home Assistant disconnected".into())),
                Ok(message) => Poll::Ready(Ok(message)),
                Err(error) if would_block(&error) => Poll::Pending,
                Err(_) => Poll::Ready(Err("Home Assistant connection failed".into())),
            }
        }).await
    }

    pub(super) async fn send(&mut self, message: Message) -> Result<(), String> {
        let mut message = Some(message);
        poll_fn(|cx| {
            self.0.get_mut().waker.clone_from(cx.waker());
            let result = match message.take() {
                Some(message) => self.0.send(message),
                None => self.0.flush(),
            };
            match result {
                Ok(()) => Poll::Ready(Ok(())),
                // A WouldBlock from send leaves the frame buffered; retry only the flush.
                Err(error) if would_block(&error) => Poll::Pending,
                Err(_) => Poll::Ready(Err("Home Assistant send failed".into())),
            }
        }).await
    }
}
