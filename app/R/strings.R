# Every user-facing string of the app, in English (master doc 6.2 [v2]).
# Modules read copy from here; nothing user-visible is written inline.

app_title <- "Decide as Taxi Driver For A Day"
app_subtitle <- "NYC Taxi Decision Simulator"

nav_setup <- "Setup"
nav_trips <- "Trips"
nav_results <- "Results"

# ---- setup -----------------------------------------------------------------
setup_intro_1 <- paste(
  "This app will help you to validate what is the best strategy to work as a",
  "taxi driver in NYC and increase the earning without working any extra hour."
)
setup_intro_2_a <- "If you want to see the whole process before getting in the app please check "
setup_intro_2_b <- "this web site"
setup_intro_2_c <- " and the corresponding "
setup_intro_2_d <- "repo"
setup_intro_2_e <- "."

setup_lead <- paste(
  "Define the initial conditions that will keep constant during the whole",
  "8 hours of a working day."
)

label_company <- "Taxi Company"
label_start_datetime <- "Initial Date-time"
label_start_zone <- "Initial Location"
label_seed_section <- "Advanced"
label_seed <- "Random seed"
seed_help <- paste(
  "Changing the seed changes the simulation results, and your result will be",
  "marked as unofficial."
)

btn_validate <- "Validate Starting Conditions"
btn_validating <- "Validating..."
btn_start <- "Start The Day"
btn_starting <- "Starting..."

# Hints derived from POST /validate-trip-start (better_company / better_datetime)
hint_company_fmt <- "Use %s for better results"
hint_datetime_fmt <- "Start at %s for better results"
msg_perfect <- "Conditions are perfect to get the best results"

label_result_card <- "Send me my result card"
label_marketing <- "I agree to be contacted about Data Science services"
label_email <- "Email"
label_privacy <- "Privacy notice"

label_resume_section <- "Have a code?"
resume_lead <- paste(
  "Enter the experiment ID and the resume code you got when you started a day",
  "to pick it up where you left it."
)
label_resume_id <- "Experiment ID"
label_resume_code <- "Resume code"
btn_resume <- "Resume"
btn_resuming <- "Resuming..."
btn_new_day <- "Start a new day instead"
err_email <- "Enter a valid email address."
err_resume_fields <- "Fill in both the experiment ID and the resume code."
err_zone_required <- "Select your starting zone."
btn_close <- "Close"

# ---- confirm modal ---------------------------------------------------------
modal_title <- "Your day is ready"
modal_lead <- paste(
  "Copy your resume code now: it is shown only once, and it is what lets you",
  "come back to this day from another device."
)
label_resume_code_copy <- "Resume code"
btn_copy <- "Copy"
btn_copied <- "Copied!"
btn_continue <- "Continue to Trips"

# ---- header ----------------------------------------------------------------
status_none <- "No day yet"
status_setup <- "Preparing your day"
status_in_progress <- "Day in progress"
status_finished <- "Day finished"
status_abandoned <- "Day abandoned"
label_progress <- "Preparing the model trajectories"

# ---- trips -----------------------------------------------------------------
label_current_time <- "Current Time"
label_pending_time <- "Pending Time"
label_trip_card <- "Trip to confirm"
label_trip_miles <- "Trip Miles"
label_trip_time <- "Trip Time (h:m)"
label_trip_pay <- "Pay $$"
label_current_location <- "Current Location"
label_pickup_zone <- "Pickup Zone"
label_dropoff_zone <- "Drop-off Zone"
label_pu_selector <- "Change Pickup Zone"
label_do_selector <- "Change Drop-off Zone"
label_zone_placeholder <- "Search a TLC zone"
label_sensitivity_idle <- "Pick another pickup or drop-off zone to see how the decision boundary moves."
btn_accept <- "Accept Trip"
btn_reject <- "Reject Trip"
btn_busy <- "Sending..."
label_sensitivity <- "Model Results"
label_sensitivity_plot <- "Decision boundary by zone"
label_history <- "Cumulative pay"
label_curve_user <- "You"
label_curve_policy <- "Model"
label_curve_baseline <- "Accept all"
label_no_day <- "Start a day in the Setup tab first."
label_no_trip <- "Waiting for the next trip..."
label_model_accept <- "Accept trip"
label_model_reject <- "Reject trip"
label_trips_idle <- "The day is still being prepared. This can take up to two minutes."
label_trips_finished <- "The shift is over -- your results are ready."

# Sidebar (6.5): KPIs plus the discrete button that shows the code again.
# Deliberately no live % vs policy here: section 3.11 reserves any comparison
# for Results, and a running agreement score would be exactly the pressure the
# rule is meant to avoid.
label_earnings <- "Earnings so far"
label_decisions <- "Decisions"
label_resume_code_btn <- "My resume code"
modal_resume_title <- "Your resume code"

# Keyboard shortcuts (6.5). The words live here so nothing user-visible is
# written inline; the arrows are Font Awesome icons, not unicode literals.
kbd_title <- "Keyboard shortcuts"
kbd_arrow_left <- "preselect Reject"
kbd_arrow_right <- "preselect Accept"
kbd_enter <- "confirm the preselected option"
kbd_question <- "open this dialog"
kbd_escape <- "close this dialog and clear the preselection"
kbd_note <- paste(
  "A direct click or tap confirms the decision right away. The keys only",
  "preselect, so a stray keypress never sends an irreversible decision."
)

# ---- results ---------------------------------------------------------------
label_results_empty <- "No finished day yet."
label_kpi_earnings <- "Total Earnings"
label_kpi_hourly <- "Hourly Wage"
label_kpi_vs_policy <- "vs Policy"
label_kpi_accepted <- "Trips Accepted"
label_kpi_rejected <- "Trips Rejected"
label_kpi_following <- "% Following Policy"
label_results_title <- "Your day is over"

# Under the curves (4.6): the percentile is a sentence, never a seventh KPI.
fmt_percentile <- "Your day ranked at the %s percentile of 1,000 simulated model days."
note_percentile <- "One day is a single sample, so read it as a snapshot, not as a ranking."
badge_custom_seed <- "Custom seed \u2014 unofficial"
msg_no_rides <- "You rejected every ride, so your day ended at $0."
label_technical <- "Technical details"
label_experiment_id <- "Experiment ID"
label_model_version <- "Model"
label_company_detail <- "Company"

# ---- feedback --------------------------------------------------------------
label_feedback_btn <- "Send feedback"
label_feedback_title <- "How was your day?"
label_feedback_rating <- "Rating"
label_feedback_comment <- "Comment (optional)"
label_feedback_public <- "Show my comment publicly"
label_feedback_public_help <- "Your name is never shown; comments are anonymous."
btn_feedback_submit <- "Send"
btn_feedback_close <- "Not now"
msg_feedback_saved <- "Feedback saved. Thank you."
err_feedback_rating <- "Pick a rating before sending."

# ---- generic ---------------------------------------------------------------
err_api_prefix <- "API error:"
msg_api_unavailable <- "The API is not reachable. Please try again in a moment."
