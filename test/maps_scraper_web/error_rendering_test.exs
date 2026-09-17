defmodule MapsScraperWeb.ErrorRenderingTest do
  @moduledoc """
  Setelah `ErrorHTML` dihapus, satu-satunya format error yang tersisa adalah JSON.
  Test ini menjaga agar rute yang tidak dikenal tetap membalas JSON — bukan
  meledak karena mencari template HTML yang sudah tidak ada.
  """
  use MapsScraperWeb.ConnCase, async: true

  test "rute tidak dikenal membalas 404 berbentuk JSON", %{conn: conn} do
    conn = get(conn, "/tidak-ada")

    assert conn.status == 404
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert Jason.decode!(conn.resp_body) == %{"errors" => %{"detail" => "Not Found"}}
  end

  test "rute tidak dikenal tetap JSON walau klien meminta HTML", %{conn: conn} do
    conn = conn |> put_req_header("accept", "text/html") |> get("/")

    assert conn.status == 404
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert Jason.decode!(conn.resp_body)["errors"]["detail"] == "Not Found"
  end
end
