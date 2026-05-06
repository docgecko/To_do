defmodule ToDo.AvatarStorage.S3 do
  @moduledoc """
  Generic S3-compatible backend.

  Works against any S3 API: Cloudflare R2, Tigris, AWS S3, MinIO, etc.
  The endpoint, bucket, public URL prefix, and credentials all come from
  config so the same code path covers all of them.

  Configured at runtime (see `config/runtime.exs`):

      config :to_do, :avatar_storage_s3,
        bucket: System.get_env("S3_BUCKET"),
        public_base: System.get_env("S3_PUBLIC_BASE")

      config :ex_aws, :s3, ...                # endpoint + region
      config :ex_aws, access_key_id: ..., secret_access_key: ...

  The bucket is expected to allow public reads on the `avatars/` prefix —
  avatar URLs land directly in `<img src=...>` tags. For R2 that means
  enabling public access on the bucket (gets you a `pub-<hash>.r2.dev`
  URL) or attaching a custom domain.
  """

  @behaviour ToDo.AvatarStorage

  @impl true
  def put(tmp_path, filename) do
    %{bucket: bucket, public_base: public_base} = conf()
    key = "avatars/" <> filename
    body = File.read!(tmp_path)

    op =
      ExAws.S3.put_object(bucket, key, body,
        content_type: content_type_for(filename),
        cache_control: "public, max-age=31536000, immutable"
      )

    case ExAws.request(op) do
      {:ok, _} -> {:ok, public_base <> "/" <> key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(value) when is_binary(value) do
    %{bucket: bucket, public_base: public_base} = conf()

    case String.split(value, public_base <> "/", parts: 2) do
      [_, key] ->
        ExAws.S3.delete_object(bucket, key) |> ExAws.request()
        :ok

      _ ->
        # Stored value isn't an S3 URL we recognise; treat as a no-op so
        # the caller can swap backends without orphaning the user's row.
        :ok
    end
  end

  def delete(_), do: :ok

  defp conf do
    cfg = Application.fetch_env!(:to_do, :avatar_storage_s3)
    %{bucket: Keyword.fetch!(cfg, :bucket), public_base: Keyword.fetch!(cfg, :public_base)}
  end

  defp content_type_for(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
