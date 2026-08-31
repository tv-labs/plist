defmodule Plist.Error do
  @moduledoc """
  Raised when plist encoding or decoding fails.
  """

  defexception [:message, :reason, :operation]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: term(),
          operation: :encode | :decode
        }

  @impl true
  def exception(opts) do
    operation = Keyword.fetch!(opts, :operation)
    reason = Keyword.fetch!(opts, :reason)

    message =
      case operation do
        :encode -> "failed to encode plist: #{format_reason(reason)}"
        :decode -> "failed to decode plist: #{format_reason(reason)}"
      end

    %__MODULE__{message: message, reason: reason, operation: operation}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
