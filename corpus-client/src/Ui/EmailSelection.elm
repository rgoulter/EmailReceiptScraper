module Ui.EmailSelection exposing
  ( Model
  , Msg
  , init
  , empty
  , getEmails
  , getFailure
  , getSelection
  , isLoading
  , modelFromEmails
  , navigate
  , setDateFilter
  , setSelection
  , update
  , view
  )

import Array exposing (Array)
import Array

import Email exposing (Email, emailsDecoder)

import Html as H
import Html.Attributes as A
import Html.Events as E
import Html exposing (Html, div, text, select, option)
import Html.Attributes exposing (class)
import Html.Events.Extra exposing (onChange)

import Http

import KeyboardNavigation

import Time




-- MODEL


type alias Filters =
  { dateRange : Maybe (Time.Posix, Time.Posix)
  }


type alias Emails =
  { selected : Int
  , emails : Array Email
  , filters : Filters
  }


type Model
  = Failure String
  | Loading Filters
  | Empty
  | Success Emails


init : () -> (Model, Cmd Msg)
init _ =
  let
    initFilters = { dateRange = Nothing }
  in
  (Loading initFilters, getEmailsRequest initFilters)


empty : Model
empty = Empty


isLoading : Model -> Bool
isLoading model =
  case model of
    Loading _ -> True
    _ -> False


getFailure : Model -> Maybe String
getFailure model =
  case model of
    Failure message -> Just message
    _ -> Nothing


getEmails : Model -> Array Email
getEmails model =
  case model of
    Success { emails } -> emails
    _ -> Array.empty


getSelection : Model -> Maybe (Int, Email)
getSelection model =
  case model of
    Success { selected, emails } ->
      Maybe.map (\e -> (selected, e)) (Array.get selected emails)
    _ -> Nothing


setSelection : Model -> Int -> Email -> Model
setSelection model index updatedEmail =
  case model of
    Success emails ->
      Success { emails | emails = Array.set index updatedEmail emails.emails }
    _ -> model


getFilterDateRange : Model -> Maybe (Time.Posix, Time.Posix)
getFilterDateRange model =
  case model of
    Loading filters -> filters.dateRange
    Success emails -> emails.filters.dateRange
    _ -> Nothing


setDateFilter : Model -> (Maybe (Time.Posix, Time.Posix)) -> (Model, Cmd Msg)
setDateFilter model dateRange =
  let
    oldDateRange = getFilterDateRange model
  in
  {-
     IMPL. NOTE:
     Checking dateRange /= oldDateRange is b/c
     I have Main's update call this setDateFilter function
      on every DateFilterMsg;
     DateFilterMsg is also used by the EDRP.
     (And b/c of how Main handles Ui.EmailSelection's Loading,
      this ends up thrashing the UI a lot and is functionally
      unusable).

     It might be better to try and have Ui.DateFilter have a
      "DateFilterChanged" message.
  -}
  if dateRange /= oldDateRange then
    let
      updateFilters f = { f | dateRange = dateRange }
      filters =
        case model of
          Loading oldFilters -> updateFilters oldFilters
          Success emails -> updateFilters emails.filters
          _ -> { dateRange = Nothing }
      getEmailsCmd = getEmailsRequest filters
    in
    case model of
      Loading _ -> (Loading filters, getEmailsCmd)
      -- Bad UX? Wipes state on changing date range
      Success _ -> (Loading filters, getEmailsCmd)
      _ -> (model, Cmd.none)
  else
    (model, Cmd.none)


-- Helper method for the Showcase.
modelFromEmails : Int -> Array Email -> Model
modelFromEmails selected emails =
  if selected > Array.length emails then
    Empty
  else
    let
      filters = { dateRange = Nothing }
    in
    Success { selected = selected, filters = filters, emails = emails }



-- UPDATE


type Msg
  = FetchEmails Filters
  | GotEmails Filters (Result Http.Error (Array Email))
  | Noop
  | SelectEmail Int


update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
    FetchEmails filters ->
      (Loading filters, getEmailsRequest filters)

    GotEmails filters result ->
      case result of
        Ok emails ->
          if Array.isEmpty emails then
            (Empty, Cmd.none)
          else
            ( Success { selected = 0, filters = filters, emails = emails }
            , Cmd.none
            )

        Err error ->
          let
            errorMessage =
              case error of
                Http.BadUrl url -> String.concat ["Bad Url: ", url]
                Http.Timeout -> "Request timed out"
                Http.NetworkError -> "Network error"
                Http.BadStatus statusCode -> String.concat ["Bad status code: ", String.fromInt statusCode]
                Http.BadBody message -> String.concat ["Bad body:", message]
          in
          (Failure (String.concat ["GET /email-addresses failed: ", errorMessage]), Cmd.none)

    Noop -> (model, Cmd.none)

    SelectEmail index ->
      case model of
        Success emails -> (Success { emails | selected = index }, Cmd.none)
        _ -> (model, Cmd.none)


navigate : KeyboardNavigation.Direction -> Model -> (Model, Cmd Msg)
navigate direction model =
  case model of
    Success emails ->
      let
        newSelected =
          case direction of
            KeyboardNavigation.Previous -> emails.selected - 1
            KeyboardNavigation.Next -> emails.selected + 1
        clamp x min max =
          if x < min then
            min
          else
            if x >= max then
              max - 1
            else
              x
        clampedSelected = clamp newSelected 0 (Array.length emails.emails)
      in
        (Success { emails | selected = clampedSelected }, Cmd.none)
    _ -> (model, Cmd.none)




-- VIEW


view : Model -> Html Msg
view model =
   case model of
     Success { emails, selected } ->
       let
         trow_from_email = \index { from, datetime, subject } ->
           let
             selectedAttr = if index == selected then [class "is-selected"] else []
             selectAttr = E.onClick (SelectEmail index)
             trAttrs = [selectAttr] ++ selectedAttr
           in
           H.tr trAttrs
                [ H.td [class "datetime", A.style "width" "15%"] [text datetime]
                , H.td [class "from", A.style "width" "25%"] [text from]
                , H.td [class "subject", A.style "width" "60%"] [text subject]
                ]
         trows = Array.toList (Array.indexedMap trow_from_email emails)
       in
       div [ A.style "overflow-y" "scroll"
           , A.style "height" "200px"
           ]
           [ H.table [class "table", A.id "emails"]
                     [H.tbody [] trows]
           ]

     -- XXX: what *should* this be.
     _ -> text "loading"


-- HTTP


filtersGetParams : Filters -> String
filtersGetParams filters =
  let
    posixToStr p = String.fromInt ((Time.posixToMillis p) // 1000)
    dateParams =
      case filters.dateRange of
        Nothing -> [""]
        Just (start_ts, end_ts) ->
          [("after=" ++ posixToStr start_ts), ("before=" ++ posixToStr end_ts)]
    dateParamsStr =
      String.join "&" dateParams
  in
    "?" ++ dateParamsStr



getEmailsRequest : Filters -> Cmd Msg
getEmailsRequest filters =
  Http.get
    { url = "/api/emails" ++ (filtersGetParams filters)
    , expect = Http.expectJson (GotEmails filters) emailsDecoder
    }
